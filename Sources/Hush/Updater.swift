// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CryptoKit
import HushKit

/// Updates the app from a GitHub release (a prebuilt disk image) or from the repo's main branch (built locally):
/// check GitHub, fetch, verify, swap the bundle in after quitting, and roll back if the new version doesn't start.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    enum Phase: Equatable { case idle, checking, working(String), failed(String) }

    var phase: Phase = .idle
    var status: UpdateStatus?
    var lastChecked: Date?
    var notice: String?
    var log: [String] = []
    /// 0...1 while a download runs, nil when the step has no measurable progress.
    var progress: Double?
    var lastResult: String?
    /// The last failure in plain words, with a hint and the technical detail for the log.
    var problem: AppProblem?
    private var step = "Checking for updates"
    let build = BuildInfo.current
    private var nextAutoCheck = Date()

    private var root: URL {
        let url = AppPaths().root
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var markerURL: URL { root.appendingPathComponent("update-ok") }
    private var pendingURL: URL { root.appendingPathComponent("update-pending.json") }
    private var logURL: URL { root.appendingPathComponent("update.log") }

    var isBundled: Bool { Bundle.main.bundlePath.hasSuffix(".app") && build.commit != nil }
    var busy: Bool { if case .checking = phase { return true }; if case .working = phase { return true }; return false }
    var available: UpdateInfo? { if case .available(let i)? = status { return i }; return nil }
    var savedLog: [String] { (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [] }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
        if let data = (line + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: logURL) }
        }
    }

    /// Turns any error into a friendly problem, shows it, and writes it to the shared error log. Never throws.
    @discardableResult
    private func fail(_ error: Error, quiet: Bool = false) -> AppProblem {
        let p = AppProblem.from(error)
        append("✗ \(p.title). \(p.detail)")
        AppModel.shared.record(p, step: step)
        if !quiet { problem = p; phase = .failed(p.title) }
        return p
    }

    func copyDetails() { if let p = problem { AppModel.shared.copyDetails(p, step: step) } }
    func reportOnGitHub() { if let p = problem { AppModel.shared.sendReport(p, step: step) } }
    var errorLogURL: URL { AppModel.shared.errorLog.url }

    private func beginRun(to target: String) {
        problem = nil
        log = []
        try? FileManager.default.removeItem(at: logURL)
        append("Update \(build.version) · \(build.shortCommit) → \(target) at \(Date().formatted())")
        let info = ["from": build.cleanCommit ?? build.version, "fromVersion": build.version, "to": target]
        try? JSONSerialization.data(withJSONObject: info).write(to: pendingURL)
    }

    // MARK: Launch bookkeeping

    /// Tells a pending swap script this version started fine, and reports what the last update did.
    func confirmLaunch() {
        let fm = FileManager.default
        let swapLog = (try? String(contentsOf: root.appendingPathComponent("swap.log"), encoding: .utf8)) ?? ""
        for name in ["staging", "swap.sh", "swap.log"] { try? fm.removeItem(at: root.appendingPathComponent(name)) }
        let failedURL = URL(fileURLWithPath: markerURL.path + ".failed")
        let failure = (try? String(contentsOf: failedURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? fm.removeItem(at: failedURL)
        if let data = try? Data(contentsOf: pendingURL), let pending = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            try? fm.removeItem(at: pendingURL)
            let now = build.cleanCommit ?? build.version
            let target = pending["to"] ?? ""
            let arrived = failure == nil && (now.hasPrefix(target) || target.hasPrefix(now) || "v\(build.version)" == target
                                             || (pending["from"] != now && pending["fromVersion"] != build.version))
            if arrived {
                lastResult = "Updated to \(build.version) · \(build.shortCommit)"
                append("Started fine: \(build.version) · \(build.shortCommit)")
                AppModel.shared.show(lastResult ?? "Updated")
            } else {
                let why = failure ?? "The new version didn't replace the old one."
                notice = why
                step = "Restarting into the new version"
                fail(UpdateError.verifyFailed(why), quiet: true)
                swapLog.split(separator: "\n").forEach { append(String($0)) }
                AppModel.shared.show(why, error: true)
            }
        } else if let failure { notice = failure }
        Task {
            try? await Task.sleep(for: .seconds(4))
            try? Data().write(to: markerURL)
        }
    }

    // MARK: Check

    /// At most once a day and quietly. No timers of its own: it is called at launch.
    func autoCheckIfDue(enabled: Bool) {
        guard enabled, isBundled, !busy, Date() >= nextAutoCheck else { return }
        nextAutoCheck = Date().addingTimeInterval(24 * 3600)
        Task { await check(silent: true) }
    }

    func check(silent: Bool = false) async {
        guard !busy else { return }
        guard build.cleanCommit != nil || build.version != "0.0.0" else { status = .notComparable("This is a development build."); return }
        phase = .checking; step = "Checking for updates"; problem = nil
        do {
            status = try await UpdateChecker().check(build, allowBranch: Prefs.shared.updateChannel == .main)
            lastChecked = Date()
            phase = .idle
            if !silent, case .upToDate? = status { AppModel.shared.show("hush is up to date") }
        } catch {
            nextAutoCheck = Date().addingTimeInterval(3600)
            if silent { fail(error, quiet: true); phase = .idle } else { fail(error) }
        }
    }

    // MARK: Install

    func install() async {
        guard let info = available, !busy else { return }
        if let release = info.release { await installRelease(release); return }
        beginRun(to: info.sha); step = "Preparing"
        do {
            try preflight()
            phase = .working("Checking the build tools"); step = "Checking the build tools"
            let src = root.appendingPathComponent("source", isDirectory: true)
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            let head = try await Toolchain.installFromSource(
                run: Self.toolchainRunner,
                selected: { choice in Task { @MainActor in Updater.shared.append(Privacy.scrub(Toolchain.logLine(choice))) } },
                fetch: {
                    phase = .working("Getting the source"); step = "Getting the source"
                    return try await fetchSource(into: src, sha: info.sha)
                },
                build: { _, env in
                    phase = .working("Building. This takes a few minutes"); step = "Building"
                    try? FileManager.default.removeItem(at: staging)
                    try await run("/usr/bin/nice", ["-n", "10", "/bin/bash", "scripts/bundle.sh", build.version], cwd: src, env: env.merging(["DIST_DIR": staging.path]) { _, new in new }) { .buildFailed($0) }
                })

            phase = .working("Checking the new build"); step = "Checking the new build"
            let staged = staging.appendingPathComponent("Hush.app")
            try await verify(staged, expect: head)

            phase = .working("Restarting"); step = "Restarting"
            try startSwap(new: staged)
            NSApp.terminate(nil)
        } catch {
            fail(error)
        }
    }

    /// Runs the toolchain probe's commands for real. A tool that cannot start or times out counts as a failure.
    private static let toolchainRunner: Toolchain.Runner = { tool, args, env in
        guard let r = try? await Shell.run(tool, args, env: env, timeout: Toolchain.probeTimeout) else { return .init(status: 1) }
        return .init(status: r.status, text: r.stdout + r.stderr)
    }

    /// Prebuilt path: download the disk image, check its hash, unpack, verify, swap. No Xcode tools needed.
    private func installRelease(_ release: ReleaseInfo) async {
        beginRun(to: release.tag); step = "Preparing"
        let fm = FileManager.default
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let mount = staging.appendingPathComponent("mnt", isDirectory: true)
        var mounted = false
        do {
            try preflight(needsBuildTools: false)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)

            phase = .working("Downloading \(release.tag)"); step = "Downloading"
            let dmg = staging.appendingPathComponent(release.dmgName)
            try await download(release.dmgURL, to: dmg)

            phase = .working("Checking the download"); step = "Checking the download"
            try await verifyChecksum(of: dmg, release: release)

            phase = .working("Unpacking"); step = "Unpacking"
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path]) { .verifyFailed("Couldn't open the disk image. \($0)") }
            mounted = true
            let staged = staging.appendingPathComponent("Hush.app")
            try await run("/usr/bin/ditto", [mount.appendingPathComponent("Hush.app").path, staged.path]) { .verifyFailed("The disk image has no app. \($0)") }
            try await run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) { .verifyFailed($0) }
            mounted = false
            try? fm.removeItem(at: dmg)

            phase = .working("Checking the new build"); step = "Checking the new build"
            try await verify(staged, expect: nil)

            phase = .working("Restarting"); step = "Restarting"
            try startSwap(new: staged)
            NSApp.terminate(nil)
        } catch {
            if mounted { _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]) { .verifyFailed($0) } }
            fail(error)
        }
    }

    private func download(_ url: URL, to file: URL) async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network("The download failed.") }
        let total = resp.expectedContentLength
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close(); progress = nil }
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        progress = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress = Double(received) / Double(total) }
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); received += Int64(buffer.count) }
        append("Downloaded \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)).")
    }

    private func verifyChecksum(of file: URL, release: ReleaseInfo) async throws {
        guard let sumsURL = release.checksumsURL else { append("This release has no checksum file; relying on the code signature only."); return }
        let (data, _) = try await URLSession.shared.data(from: sumsURL)
        guard let sums = String(data: data, encoding: .utf8), let expected = UpdateChecker.checksum(in: sums, for: release.dmgName) else {
            throw UpdateError.verifyFailed("The checksum file doesn't list \(release.dmgName).")
        }
        let actual = try await Task.detached { () -> String in
            var hasher = SHA256()
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        guard actual == expected else { throw UpdateError.verifyFailed("The download is damaged (checksum mismatch).") }
        append("Checksum matches.")
    }

    private func preflight(needsBuildTools: Bool = true) throws {
        guard isBundled else { throw UpdateError.notBundled }
        let dest = Bundle.main.bundleURL, fm = FileManager.default
        guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path), fm.isWritableFile(atPath: dest.path) else { throw UpdateError.notWritable(dest.path) }
        guard needsBuildTools else { return }
        guard fm.isExecutableFile(atPath: "/usr/bin/git") else { throw UpdateError.missingTool("git") }
        guard fm.isExecutableFile(atPath: "/usr/bin/xcrun") else { throw UpdateError.missingTool("Swift") }
    }

    private func fetchSource(into src: URL, sha: String) async throws -> String {
        let git = "/usr/bin/git", url = "https://github.com/\(build.repo).git", fm = FileManager.default
        if !fm.fileExists(atPath: src.appendingPathComponent(".git").path) {
            try? fm.removeItem(at: src)
            try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await run(git, ["clone", "--depth", "1", "--branch", build.branch, "--single-branch", url, src.path]) { .buildFailed($0) }
        } else {
            try await run(git, ["remote", "set-url", "origin", url], cwd: src) { .buildFailed($0) }
            try await run(git, ["fetch", "--depth", "1", "origin", build.branch], cwd: src) { .buildFailed($0) }
            try await run(git, ["reset", "--hard", "FETCH_HEAD"], cwd: src) { .buildFailed($0) }
            try await run(git, ["clean", "-fd"], cwd: src) { .buildFailed($0) }
        }
        let head = try await Shell.check(git, ["-C", src.path, "rev-parse", "HEAD"], timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
        if head != sha { append("\(build.branch) moved on; building \(head.prefix(7)) instead of \(sha.prefix(7)).") }
        return head
    }

    /// `commit` is what a source build must report; a release build only has to start and say ok.
    private func verify(_ app: URL, expect commit: String?) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: app.path) else { throw UpdateError.verifyFailed("The app wasn't produced.") }
        let exe = app.appendingPathComponent("Contents/MacOS/Hush").path
        guard fm.isExecutableFile(atPath: exe), fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/hush-mcp").path) else {
            throw UpdateError.verifyFailed("The app is missing files.")
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) { .verifyFailed("Signature is invalid. \($0)") }
        let r = try? await Shell.run(exe, ["--self-test"], timeout: 20)
        guard r?.status == 0, let out = r?.stdout, commit.map({ out.contains($0) }) ?? out.hasPrefix("ok") else {
            throw UpdateError.verifyFailed("It didn't start correctly.")
        }
    }

    private func startSwap(new: URL) throws {
        let script = root.appendingPathComponent("swap.sh")
        try UpdateSwap.script.write(to: script, atomically: true, encoding: .utf8)
        let dest = Bundle.main.bundleURL
        let backup = dest.deletingLastPathComponent().appendingPathComponent("Hush.previous.app")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/bash", script.path, String(ProcessInfo.processInfo.processIdentifier), new.path, dest.path, backup.path, markerURL.path, "40"]
        let swapLog = root.appendingPathComponent("swap.log")
        FileManager.default.createFile(atPath: swapLog.path, contents: nil)
        p.standardOutput = try? FileHandle(forWritingTo: swapLog)
        p.standardError = p.standardOutput
        try p.run()
    }

    /// Runs a tool, streaming its output into the visible log.
    private func run(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:], failure: (String) -> UpdateError) async throws {
        final class Tail: @unchecked Sendable { var lines: [String] = []; var errors: [String] = [] }
        let tail = Tail()
        let status = try await Shell.stream(exe, args, cwd: cwd, env: env) { line in
            // swift prints the whole compiler command line after the real diagnostics, so keep the
            // "error:" lines apart and drop that command line from the tail.
            let short = line.count > 300 ? String(line.prefix(300)) + "…" : line
            if line.contains(" error: ") || line.hasPrefix("error: ") { if tail.errors.count < 6 || AppProblem.isMissingMacroPlugin(line.lowercased()) { tail.errors.append(short) } }
            if !line.contains(" -module-name ") && !line.hasPrefix("Command ") { tail.lines.append(short); if tail.lines.count > 8 { tail.lines.removeFirst() } }
            Task { @MainActor in Updater.shared.append(line) }
        }
        if status != 0 {
            let detail = tail.errors.isEmpty ? tail.lines.suffix(4) : tail.errors[...]
            throw failure(detail.joined(separator: " "))
        }
    }
}
