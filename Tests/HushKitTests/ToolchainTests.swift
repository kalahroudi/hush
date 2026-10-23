// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import HushKit

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// A fake shell. `good` lists the developer directories whose probe passes ("" is the user's selection).
private func fakeRunner(selected: String?, good: Set<String>, calls: Calls, swift: String = "Apple Swift version 6.1 (swiftlang-6.1)") -> Toolchain.Runner {
    { tool, args, env in
        let dir = env["DEVELOPER_DIR"] ?? ""
        calls.add(([tool] + args.map { $0.hasSuffix("Probe.swift") ? "Probe.swift" : $0 }).joined(separator: " ") + (dir.isEmpty ? "" : " @\(dir)"))
        if tool == Toolchain.xcodeSelect { return args == ["-p"] && selected != nil ? .init(status: 0, text: selected! + "\n") : .init(status: 2) }
        if args.first == "swiftc" { return .init(status: good.contains(dir) ? 0 : 1, text: "error: plugin for module 'SwiftUIMacros' not found") }
        if args.first == "swift" { return .init(status: 0, text: swift + "\nTarget: arm64-apple-macosx15.0\n") }
        return .init(status: 1)
    }
}

final class ToolchainTests: XCTestCase {
    private let xcode = "/Applications/Xcode.app/Contents/Developer"

    func testUsesSelectedToolchainWhenProbePasses() async throws {
        let calls = Calls()
        let s = try await Toolchain.resolve(run: fakeRunner(selected: "/Applications/Xcode.app/Contents/Developer", good: [""], calls: calls), xcodeApps: { ["/Applications/Xcode.app"] })
        XCTAssertEqual(s.developerDir, xcode)
        XCTAssertTrue(s.swiftVersion.contains("Swift version 6.1"))
        XCTAssertFalse(calls.all.contains { $0.contains("@") }, "the selection is probed without DEVELOPER_DIR")
    }

    func testProbeRunsAndIsATypecheckOfAStateFile() async {
        let calls = Calls()
        let ok = await Toolchain.probe(developerDir: nil, run: fakeRunner(selected: nil, good: [""], calls: calls))
        XCTAssertTrue(ok)
        XCTAssertEqual(calls.all, ["/usr/bin/xcrun swiftc -typecheck Probe.swift"])
        XCTAssertTrue(Toolchain.probeSource.contains("@State"))
    }

    func testFallsBackToInstalledXcodeWhenSelectionFails() async throws {
        let calls = Calls()
        let clt = "/Library/Developer/CommandLineTools"
        let s = try await Toolchain.resolve(run: fakeRunner(selected: clt, good: [xcode], calls: calls), xcodeApps: { ["/Applications/Xcode.app"] })
        XCTAssertEqual(s.developerDir, xcode)
        XCTAssertEqual(s.env, ["DEVELOPER_DIR": xcode])
        XCTAssertFalse(calls.all.contains { $0.hasPrefix(Toolchain.xcodeSelect + " -s") }, "never changes the global selection")
    }

    func testNoToolchainStopsWithToolchainError() async {
        let calls = Calls()
        do {
            _ = try await Toolchain.resolve(run: fakeRunner(selected: nil, good: [], calls: calls), xcodeApps: { [] })
            XCTFail("should throw")
        } catch {
            guard case UpdateError.toolchainUnusable = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(calls.all, ["/usr/bin/xcode-select -p"], "no xcrun call (and so no installer prompt) without a developer directory")
    }

    func testXcodeOlderThanSwift6IsRejected() async {
        let calls = Calls()
        let run = fakeRunner(selected: nil, good: [xcode], calls: calls, swift: "Apple Swift version 5.10")
        do { _ = try await Toolchain.resolve(run: run, xcodeApps: { ["/Applications/Xcode.app"] }); XCTFail("should throw") } catch {}
    }

    func testNewestXcodeIsTriedFirst() {
        XCTAssertEqual(Toolchain.sortedNewestFirst(["Xcode-15.4.app", "Xcode-16.2.app", "Xcode.app"]), ["Xcode.app", "Xcode-16.2.app", "Xcode-15.4.app"])
    }

    func testLogLineNamesToolchainAndIsScrubbed() {
        let s = Toolchain.Selection(developerDir: "/Users/mehdi/Apps/Xcode.app/Contents/Developer", swiftVersion: "Apple Swift version 6.1")
        let line = Toolchain.logLine(s)
        XCTAssertTrue(line.contains("/Contents/Developer")); XCTAssertTrue(line.contains("Swift version 6.1"))
        let scrubbed = Privacy.scrub(line, home: "/Users/mehdi", user: "mehdi", host: "h")
        XCTAssertFalse(scrubbed.contains("mehdi")); XCTAssertTrue(scrubbed.contains("Swift version 6.1"))
    }

    func testToolchainProblemMentionsFixesAndUntouched() {
        let p = AppProblem.from(UpdateError.toolchainUnusable("none"))
        let text = p.title + " " + p.hint
        for word in ["Xcode", "xcode-select", "Releases", "Your current Hush is untouched."] { XCTAssertTrue(text.contains(word), word) }
        XCTAssertNotEqual(p.title, "The new version couldn't be built")
    }
}
