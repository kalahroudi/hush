// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Runs scripts/test-toolchain.sh: bundle.sh with a stubbed `swift` that fails the macro probe must print the
/// full-Xcode guidance and exit non-zero before building anything.
final class ScriptTests: XCTestCase {
    func testBundleScriptStopsWithGuidanceWhenToolchainProbeFails() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = Process()
        p.executableURL = root.appendingPathComponent("scripts/test-toolchain.sh")
        p.currentDirectoryURL = root
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, text)
    }
}
