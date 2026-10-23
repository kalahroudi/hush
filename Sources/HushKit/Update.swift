// SPDX-License-Identifier: Apache-2.0

import Foundation

// Self-update model. The approach follows the mlxplayer app:
//   1. Prefer the latest published GitHub release (a signed disk image; this path needs no developer tools).
//   2. Otherwise compare this build's commit with the head of the branch and build from source.
//   3. Verify, swap the app bundle after quitting, and roll back if the new one never reports in.

/// Which build is running. Written into Info.plist by scripts/bundle.sh.
public struct BuildInfo: Equatable, Sendable {
    public var commit: String?
    public var repo: String
    public var branch: String
    public var version: String

    public init(commit: String?, repo: String = "kalahroudi/hush", branch: String = "main", version: String = "0") {
        self.commit = commit; self.repo = repo; self.branch = branch; self.version = version
    }

    /// The running app's build info.
    public static var current: BuildInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return BuildInfo(commit: info["HushCommit"] as? String, repo: info["HushRepo"] as? String ?? "kalahroudi/hush",
                         branch: info["HushBranch"] as? String ?? "main", version: info["CFBundleShortVersionString"] as? String ?? "0.0.0")
    }

    /// The commit without a "-dirty" marker (the build had uncommitted changes).
    public var cleanCommit: String? {
        guard let c = commit, c != "unknown", !c.isEmpty else { return nil }
        return c.hasSuffix("-dirty") ? String(c.dropLast(6)) : c
    }
    public var isDirty: Bool { commit?.hasSuffix("-dirty") == true }
    public var shortCommit: String { cleanCommit.map { String($0.prefix(7)) } ?? "dev" }
}

/// A published GitHub release with a prebuilt disk image.
public struct ReleaseInfo: Equatable, Sendable {
    public var tag: String
    public var version: String
    public var notes: [String]
    public var dmgURL: URL
    public var dmgName: String
    public var checksumsURL: URL?
}

public struct UpdateInfo: Equatable, Sendable {
    public var sha: String
    public var aheadBy: Int
    public var summaries: [String]
    /// Set when the update is a prebuilt release instead of a build from source.
    public var release: ReleaseInfo?
    public var shortSha: String { String(sha.prefix(7)) }
    public var label: String { release?.tag ?? shortSha }

    public init(sha: String, aheadBy: Int, summaries: [String], release: ReleaseInfo? = nil) {
        self.sha = sha; self.aheadBy = aheadBy; self.summaries = summaries; self.release = release
    }
}

/// Dotted versions such as "0.2.0" or "v1.4.1-beta.2". A pre-release sorts before its final.
public enum Version {
    public static func parse(_ s: String) -> (numbers: [Int], pre: String?)? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let parts = t.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard let core = parts.first else { return nil }
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, !nums.contains(where: { $0 == nil }) else { return nil }
        return (nums.compactMap { $0 }, parts.count > 1 ? String(parts[1]) : nil)
    }

    /// True when `a` is higher than `b`. Unparseable versions are never newer.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        for i in 0..<max(x.numbers.count, y.numbers.count) {
            let l = i < x.numbers.count ? x.numbers[i] : 0, r = i < y.numbers.count ? y.numbers[i] : 0
            if l != r { return l > r }
        }
        switch (x.pre, y.pre) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (l?, r?): return l.compare(r, options: .numeric) == .orderedDescending
        }
    }
}

public enum UpdateStatus: Equatable, Sendable {
    case upToDate
    case available(UpdateInfo)
    /// This build can't be compared with the branch (local build, or it has commits the branch doesn't).
    case notComparable(String)
}

/// Where updates come from. Releases is the default and needs no developer tools.
public enum UpdateChannel: String, CaseIterable, Sendable {
    case releases, main
    public static let `default`: UpdateChannel = .releases
    public var label: String { self == .releases ? "Releases" : "Main branch" }
    public init(stored: String?) { self = stored.flatMap(UpdateChannel.init(rawValue:)) ?? .default }

    /// Settings copy. Kept here so a test can check it never says Command Line Tools alone are enough.
    public static let settingDescription = "Releases: signed disk images, the safe default, no tools needed. Main branch: also offers a build of the newest commit (needs a full Xcode)."
    public static func updatesFootnote(branch: String) -> String {
        "Releases install a signed disk image: it is downloaded, checked against its SHA-256, verified, swapped in after the app quits, and rolled back automatically if the new version doesn't start. Without a release, the app can build the newest commit of \(branch) (needs a full Xcode; Releases need nothing)."
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case network(String), rateLimited, badResponse, missingTool(String), notBundled, notWritable(String), buildFailed(String), verifyFailed(String), toolchainUnusable(String)

    public var errorDescription: String? {
        switch self {
        case .network(let m): return "Couldn't reach GitHub. \(m)"
        case .rateLimited: return "GitHub is limiting requests. Try again in a few minutes."
        case .badResponse: return "GitHub sent an answer that couldn't be read."
        case .missingTool(let t): return "\(t) is needed to build the update. A full Xcode is needed (or switch the update channel to Releases, which needs no tools)."
        case .notBundled: return "Updates work from the installed app, not from a development build."
        case .notWritable(let p): return "No permission to replace \(p). Move the app to a folder you own."
        case .buildFailed(let m): return "The build failed. \(m)"
        case .verifyFailed(let m): return "The new build didn't pass checks, so nothing was replaced. \(m)"
        case .toolchainUnusable(let m): return "\(AppProblem.toolchainTitle). \(m)"
        }
    }
}

/// Asks GitHub whether a newer release exists, or whether the branch has commits this build lacks.
public struct UpdateChecker: Sendable {
    public var session: URLSession
    public var apiBase = "https://api.github.com"

    public init(session: URLSession = .shared) { self.session = session }

    /// - allowBranch: when no newer release exists, also offer a build of the newest commit on the branch.
    public func check(_ build: BuildInfo, allowBranch: Bool = true) async throws -> UpdateStatus {
        // A newer prebuilt release wins: it installs without Xcode tools.
        if let release = try await latestRelease(repo: build.repo), Version.isNewer(release.version, than: build.version) {
            return .available(UpdateInfo(sha: release.tag, aheadBy: 0, summaries: release.notes, release: release))
        }
        guard allowBranch else { return .upToDate }
        guard let current = build.cleanCommit else { return .notComparable("This build has no commit recorded.") }
        let head = try await headSHA(repo: build.repo, branch: build.branch)
        if head == current { return .upToDate }
        let (data, code) = try await get("/repos/\(build.repo)/compare/\(current)...\(head)")
        if code == 404 { return .notComparable("This build isn't on \(build.branch) yet.") }
        guard code == 200 else { throw UpdateError.badResponse }
        return try Self.decide(compareJSON: data, head: head)
    }

    public func latestRelease(repo: String) async throws -> ReleaseInfo? {
        let (data, code) = try await get("/repos/\(repo)/releases/latest")
        if code == 404 { return nil }
        guard code == 200 else { throw UpdateError.badResponse }
        return Self.parseRelease(data)
    }

    public static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["draft"] as? Bool != true, obj["prerelease"] as? Bool != true,
              let tag = obj["tag_name"] as? String else { return nil }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        func url(_ a: [String: Any]) -> URL? { (a["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let dmgName = dmg["name"] as? String, let dmgURL = url(dmg) else { return nil }
        let sums = assets.first { ($0["name"] as? String)?.uppercased().hasPrefix("SHA256SUMS") == true }
        let notes = ((obj["body"] as? String) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -*#\r")) }.filter { !$0.isEmpty }
        return ReleaseInfo(tag: tag, version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, notes: Array(notes.prefix(8)),
                           dmgURL: dmgURL, dmgName: dmgName, checksumsURL: sums.flatMap(url))
    }

    /// Finds the hash for `file` in `shasum -a 256` output ("<hash>  <name>" per line).
    public static func checksum(in sums: String, for file: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == file else { continue }
            return String(parts[0]).lowercased()
        }
        return nil
    }

    func headSHA(repo: String, branch: String) async throws -> String {
        let (data, code) = try await get("/repos/\(repo)/commits/\(branch)")
        guard code == 200, let sha = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["sha"] as? String else { throw UpdateError.badResponse }
        return sha
    }

    /// Pure, so tests can feed it saved responses.
    public static func decide(compareJSON data: Data, head: String) throws -> UpdateStatus {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let status = obj["status"] as? String else { throw UpdateError.badResponse }
        switch status {
        case "identical", "behind": return .upToDate
        case "ahead":
            let commits = obj["commits"] as? [[String: Any]] ?? []
            let lines = commits.compactMap { ($0["commit"] as? [String: Any])?["message"] as? String }.map { String($0.split(separator: "\n").first ?? "") }
            return .available(UpdateInfo(sha: head, aheadBy: obj["ahead_by"] as? Int ?? 0, summaries: Array(lines.suffix(8))))
        default: return .notComparable("This build has changes that aren't on the branch.")
        }
    }

    private func get(_ path: String) async throws -> (Data, Int) {
        guard let url = URL(string: apiBase + path) else { throw UpdateError.badResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("hush-updater", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 403 || code == 429 { throw UpdateError.rateLimited }
            return (data, code)
        } catch let e as UpdateError { throw e } catch { throw UpdateError.network(error.localizedDescription) }
    }
}

/// The script that swaps the app bundle after the app quits, and puts the old one back if the new one
/// never reports in. It runs outside the app because an app can't replace itself while running.
public enum UpdateSwap {
    public static let script = """
    #!/bin/bash
    # usage: swap.sh PID NEW_APP DEST_APP BACKUP_APP OK_MARKER TIMEOUT_SECONDS [OPEN_COMMAND]
    PID="$1"; NEW="$2"; DEST="$3"; BAK="$4"; MARK="$5"; TIMEOUT="${6:-30}"; OPEN="${7:-open}"

    # 1. Wait for the old app to quit, then make sure it has.
    for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$PID" 2>/dev/null; then kill -9 "$PID"; sleep 0.5; fi

    # 2. Swap, keeping the old bundle until the new one proves itself.
    rm -rf "$BAK"
    if ! mv "$DEST" "$BAK"; then echo "Couldn't move the current app aside." > "$MARK.failed"; $OPEN "$DEST"; exit 1; fi
    if ! mv "$NEW" "$DEST"; then
      mv "$BAK" "$DEST"; echo "Couldn't put the new app in place." > "$MARK.failed"; $OPEN "$DEST"; exit 1
    fi
    rm -f "$MARK" "$MARK.failed"
    $OPEN "$DEST"

    # 3. The new app writes the marker once it is up. No marker: roll back.
    for i in $(seq 1 $((TIMEOUT * 2))); do
      if [ -f "$MARK" ]; then rm -rf "$BAK"; exit 0; fi
      sleep 0.5
    done
    pkill -f "$DEST/Contents/MacOS/" 2>/dev/null; sleep 1
    rm -rf "$DEST"; mv "$BAK" "$DEST"
    echo "The new version didn't start, so the previous one was restored." > "$MARK.failed"
    $OPEN "$DEST"
    exit 2
    """
}

/// A failed check or update, in words a person can act on. `detail` keeps the technical text for the log.
public struct AppProblem: Equatable, Sendable {
    /// Which part of the app failed, e.g. "Update", "Telegram", "Agents". Shown in reports; never user content.
    public var area = "Update"
    public var title: String
    public var hint: String
    public var detail: String

    public init(area: String = "Update", title: String, hint: String, detail: String) { self.area = area; self.title = title; self.hint = hint; self.detail = detail }

    static let untouched = "Your current Hush is untouched."
    static let toolchainTitle = "A full Xcode is needed to build this update"
    static let toolchainHint = "Install Xcode from the App Store, or pick it with xcode-select -s /Applications/Xcode.app/Contents/Developer. Or switch the update channel to Releases, which needs no tools. \(untouched)"

    /// The compiler's text when the toolchain can't load the SwiftUI macro plugin (issue #44).
    public static func isMissingMacroPlugin(_ lower: String) -> Bool {
        (lower.contains("plugin for module") && lower.contains("not found"))
            || (lower.contains("external macro implementation type") && lower.contains("could not be found"))
    }

    public static func from(_ error: Error) -> AppProblem {
        let raw = String(describing: error) + " | " + error.localizedDescription
        if let e = error as? UpdateError {
            switch e {
            case .network(let m): return network(detail: m)
            case .rateLimited: return .init(title: "GitHub is limiting requests", hint: "Wait a few minutes and try again.", detail: raw)
            case .badResponse: return .init(title: "GitHub's answer couldn't be read", hint: "Try again later. \(untouched)", detail: raw)
            case .missingTool(let t):
                if t == "git" {
                    return .init(title: "Git is missing, and it is needed to build an update",
                                 hint: "Run xcode-select --install in Terminal to get git, or switch the update channel to Releases, which needs no tools. \(untouched)", detail: raw)
                }
                return .init(title: "\(t) is missing, and it is needed to build an update", hint: toolchainHint, detail: raw)
            case .notBundled: return .init(title: "Updates only work from the installed app", hint: "Install Hush into Applications and update from there.", detail: raw)
            case .notWritable(let p): return .init(title: "Hush can't replace itself where it is", hint: "Move Hush to Applications or a folder you own, then try again.", detail: "No write access to \(p). \(raw)")
            case .buildFailed(let m):
                let lower = m.lowercased()
                if isMissingMacroPlugin(lower) { return .init(title: toolchainTitle, hint: toolchainHint, detail: m) }
                if ["could not resolve host", "unable to access", "network is unreachable", "timed out", "connection"].contains(where: lower.contains) { return network(detail: m) }
                return .init(title: "The new version couldn't be built", hint: "\(untouched) Switch the update channel to Releases for a prebuilt version, or press Report on GitHub so we can fix it.", detail: m)
            case .toolchainUnusable(let m): return .init(title: toolchainTitle, hint: toolchainHint, detail: m)
            case .verifyFailed(let m): return .init(title: "The new version didn't pass its safety checks", hint: "Nothing was replaced. \(untouched)", detail: m)
            }
        }
        if let e = error as? URLError { return network(detail: "\(e.code.rawValue) \(e.localizedDescription)") }
        if let e = error as? ShellError {
            switch e {
            case .toolNotFound(let t): return from(UpdateError.missingTool(t))
            case .timedOut(let c): return .init(title: "A step took too long and was stopped", hint: "\(untouched) Try again.", detail: "\(c) timed out")
            case .failed(_, _, let err): return from(UpdateError.buildFailed(err))
            }
        }
        return .init(title: "Something went wrong while updating", hint: "\(untouched) Press Copy details and share it if it keeps happening.", detail: raw)
    }

    private static func network(detail: String) -> AppProblem {
        .init(title: "Couldn't reach GitHub", hint: "Check your internet connection and try again. \(untouched)", detail: detail)
    }
}

public typealias UpdateProblem = AppProblem
