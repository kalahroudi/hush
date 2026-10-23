// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Finds a developer toolchain that can build Hush from source. Building needs the SwiftUI macro plugin
/// (`@State` and friends), which ships with full Xcode and not with the Command Line Tools alone.
/// Only `DEVELOPER_DIR` is passed to child processes; the user's `xcode-select` choice is never changed.
public enum Toolchain {
    /// What a command run produced. The runner is injected so tests can use a fake shell.
    public struct Output: Sendable, Equatable {
        public var status: Int32
        public var text: String
        public init(status: Int32, text: String = "") { self.status = status; self.text = text }
    }
    /// Runs `tool args` with the given extra environment (such as `DEVELOPER_DIR`).
    public typealias Runner = @Sendable (_ tool: String, _ args: [String], _ env: [String: String]) async -> Output

    public struct Selection: Equatable, Sendable {
        /// The developer directory to export as `DEVELOPER_DIR`, or nil to use the user's selection as is.
        public var developerDir: String?
        public var swiftVersion: String
        public var env: [String: String] { developerDir.map { ["DEVELOPER_DIR": $0] } ?? [:] }
    }

    public static let xcrun = "/usr/bin/xcrun"
    public static let xcodeSelect = "/usr/bin/xcode-select"
    public static let probeTimeout: TimeInterval = 60
    static let minimumSwift = 6

    static let probeSource = """
    import SwiftUI
    struct Probe: View { @State private var n = 0; var body: some View { Text("\\(n)") } }
    """

    /// Compiles a throwaway file that uses `@State`. True when the toolchain expands SwiftUI macros.
    public static func probe(developerDir: String?, run: Runner) async -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hush-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Probe.swift")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try probeSource.write(to: file, atomically: true, encoding: .utf8)
        } catch { return false }
        let env = developerDir.map { ["DEVELOPER_DIR": $0] } ?? [:]
        return await run(xcrun, ["swiftc", "-typecheck", file.path], env).status == 0
    }

    /// Picks the toolchain for a build: the selected one if it passes the probe, otherwise the newest
    /// installed Xcode that does. Throws `UpdateError.toolchainUnusable` when none works.
    public static func resolve(run: Runner, xcodeApps: () -> [String] = installedXcodes) async throws -> Selection {
        // Without any developer directory, /usr/bin/xcrun would show Apple's installer prompt, so don't call it.
        let selected = await run(xcodeSelect, ["-p"], [:])
        if selected.status == 0, await probe(developerDir: nil, run: run), let version = await swiftVersion(developerDir: nil, run: run) {
            return Selection(developerDir: selected.text.trimmingCharacters(in: .whitespacesAndNewlines), swiftVersion: version)
        }
        for app in xcodeApps() {
            let dir = developerDir(ofApp: app)
            if await probe(developerDir: dir, run: run), let version = await swiftVersion(developerDir: dir, run: run) {
                return Selection(developerDir: dir, swiftVersion: version)
            }
        }
        throw UpdateError.toolchainUnusable("No installed developer toolchain could expand SwiftUI macros.")
    }

    /// The first line of `swift --version`, if it is Swift 6 or newer.
    static func swiftVersion(developerDir: String?, run: Runner) async -> String? {
        let env = developerDir.map { ["DEVELOPER_DIR": $0] } ?? [:]
        let out = await run(xcrun, ["swift", "--version"], env)
        guard out.status == 0, let line = out.text.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        guard let r = line.range(of: "Swift version "), let major = Int(line[r.upperBound...].prefix(while: \.isNumber)), major >= minimumSwift else { return nil }
        return line
    }

    static func developerDir(ofApp app: String) -> String { app + "/Contents/Developer" }

    /// Xcode apps in /Applications, newest version first ("Xcode.app", "Xcode-16.2.app", "Xcode_26.app" ...).
    public static func installedXcodes() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        return sortedNewestFirst(names.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }).map { "/Applications/" + $0 }
    }

    /// Plain "Xcode.app" counts as the stable one; versioned names sort by number, highest first.
    static func sortedNewestFirst(_ names: [String]) -> [String] {
        names.sorted { a, b in
            let l = a.compare(b, options: .numeric)
            return l == .orderedDescending
        }
    }

    /// The source install sequence: choose a toolchain, fetch the source, then build with that toolchain's
    /// `DEVELOPER_DIR`. Nothing is fetched or built when no toolchain passes the probe.
    public static func installFromSource<Source>(
        run: Runner,
        xcodeApps: () -> [String] = installedXcodes,
        selected: (Selection) -> Void = { _ in },
        fetch: () async throws -> Source,
        build: (_ source: Source, _ env: [String: String]) async throws -> Void
    ) async throws -> Source {
        let selection = try await resolve(run: run, xcodeApps: xcodeApps)
        selected(selection)
        let source = try await fetch()
        try await build(source, selection.env)
        return source
    }

    /// One log line naming the toolchain used for a build. Callers pass it through `Privacy.scrub`.
    public static func logLine(_ s: Selection) -> String {
        "Toolchain: \(s.developerDir ?? "selected by xcode-select"), \(s.swiftVersion)"
    }
}
