// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import HushKit

/// Runs the real hush-mcp binary over stdio against a fake Hush app on a temporary socket.
/// HUSH_NO_LAUNCH keeps the tests from ever starting the installed app.
final class MCPServerTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock(); private var items: [JSON] = []
        func add(_ r: JSON) { lock.lock(); items.append(r); lock.unlock() }
        var all: [JSON] { lock.lock(); defer { lock.unlock() }; return items }
    }

    var home = ""
    var server: ControlServer?
    let seen = Recorder()

    override func setUp() {
        home = "/tmp/hm\(getpid())\(Int.random(in: 100...999))"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDown() { server?.stop(); try? FileManager.default.removeItem(atPath: home) }

    var env: [String: String] { ["HUSH_HOME": home, "HUSH_NO_LAUNCH": "1"] }

    /// The binary SwiftPM builds next to the test bundle.
    var binary: String {
        let products = Bundle(for: MCPServerTests.self).bundleURL.deletingLastPathComponent()
        return products.appendingPathComponent("hush-mcp").path
    }

    func startApp(_ answer: @escaping @Sendable (JSON) -> JSON) throws {
        let s = ControlServer(path: AppPaths(root: URL(fileURLWithPath: home)).socketFile.path) { [seen] req in
            if req.str("op") == "ping" { return ["ok": true] }   // the server pings before every call; that is not a tool call
            seen.add(req); return answer(req)
        }
        try s.start(); server = s
    }

    func talk(_ lines: [String]) async throws -> [JSON] { try await MCPProbe.exchange(server: binary, lines: lines, env: env, timeout: 20) }

    func call(_ id: Int, _ name: String, _ args: String = "{}") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#
    }
    func result(_ r: [JSON], _ id: Int) -> JSON? { r.first { $0.int("id") == Int64(id) }?.obj("result") }
    func text(_ r: JSON?) -> String { ((r?["content"] as? [JSON])?.first?.str("text")) ?? "" }

    func testHandshakeListsToolsAndIgnoresNotifications() async throws {
        let r = try await talk([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
        ])
        XCTAssertEqual(r.count, 3, "a notification must get no reply")
        XCTAssertEqual(result(r, 1)?.str("protocolVersion"), "2025-06-18")
        XCTAssertEqual(result(r, 1)?.obj("serverInfo")?.str("name"), "hush")
        XCTAssertNotNil(result(r, 2))
        let tools = (result(r, 3)?["tools"] as? [JSON]) ?? []
        XCTAssertEqual(Set(tools.compactMap { $0.str("name") }), ["hush_status", "hush_list_chats", "hush_read", "hush_send"])
        for t in tools {
            let hint = t.obj("annotations")?.bool("readOnlyHint")
            XCTAssertEqual(hint, t.str("name") != "hush_send", "only hush_send may be non-read-only")
            XCTAssertEqual(t.obj("inputSchema")?.str("type"), "object")
        }
    }

    func testToolCallsReachTheAppWithTheirArguments() async throws {
        try startApp { req in
            switch req.str("op") {
            case "status": return ["ok": true, "signed_in_as": "Test", "online": true, "unread_chats": 2]
            case "chats": return ["ok": true, "chats": [["id": "7", "title": "Alice"]]]
            case "read": return ["ok": true, "chat": "Alice", "messages": []]
            case "send": return ["ok": true, "sent_to": "Alice"]
            default: return ["ok": false, "error": "?"]
            }
        }
        let r = try await talk([
            call(1, "hush_status"),
            call(2, "hush_list_chats", #"{"unread_only":true,"limit":5}"#),
            call(3, "hush_read", #"{"chat":"Alice","limit":10}"#),
            call(4, "hush_send", #"{"chat":"Alice","text":"hi"}"#),
        ])
        XCTAssertTrue(text(result(r, 1)).contains("\"signed_in_as\":\"Test\""))
        XCTAssertFalse(text(result(r, 1)).contains("\"ok\""), "the transport flag is not part of the tool output")
        XCTAssertTrue(text(result(r, 2)).contains("Alice"))
        XCTAssertEqual(text(result(r, 4)), "Sent to Alice.")
        for id in 1...4 { XCTAssertEqual(result(r, id)?.bool("isError"), false) }
        let ops = seen.all
        XCTAssertEqual(ops.compactMap { $0.str("op") }, ["status", "chats", "read", "send"])
        XCTAssertEqual(ops[1].bool("unread_only"), true); XCTAssertEqual(ops[1].int("limit"), 5)
        XCTAssertEqual(ops[2].str("chat"), "Alice"); XCTAssertEqual(ops[2].int("limit"), 10)
        XCTAssertEqual(ops[3].str("text"), "hi")
    }

    func testAppErrorsComeBackAsToolErrors() async throws {
        try startApp { _ in ["ok": false, "error": "The user denied this request. Do not retry."] }
        let r = try await talk([call(1, "hush_send", #"{"chat":"Alice","text":"hi"}"#)])
        XCTAssertEqual(result(r, 1)?.bool("isError"), true)
        XCTAssertEqual(text(result(r, 1)), "The user denied this request. Do not retry.")
    }

    func testBadRequestsAreRejectedWithoutReachingTheApp() async throws {
        try startApp { _ in ["ok": true] }
        let r = try await talk([
            "this is not json",
            "",
            call(1, "hush_read"),                                   // missing chat
            call(2, "hush_send", #"{"chat":"A"}"#),                 // missing text
            call(3, "no_such_tool"),
            #"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#,
            call(5, "hush_status"),                                 // still served after the garbage above
        ])
        XCTAssertTrue(text(result(r, 1)).contains("chat"))
        XCTAssertEqual(result(r, 1)?.bool("isError"), true)
        XCTAssertTrue(text(result(r, 2)).contains("text"))
        XCTAssertEqual(r.first { $0.int("id") == 3 }?.obj("error")?.int("code"), -32602)
        XCTAssertEqual(r.first { $0.int("id") == 4 }?.obj("error")?.int("code"), -32601)
        XCTAssertEqual(result(r, 5)?.bool("isError"), false)
        XCTAssertEqual(seen.all.compactMap { $0.str("op") }, ["status"], "invalid calls must not reach the app")
    }

    func testStdoutCarriesOnlyProtocolMessages() async throws {
        // exchange() throws if stdout holds anything that is not a JSON object, so a stray print would fail here.
        let r = try await talk([#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#])
        XCTAssertEqual(r.count, 1)
    }

    func testAppNotRunningGivesAHelpfulError() async throws {
        let r = try await talk([call(1, "hush_status")])
        XCTAssertEqual(result(r, 1)?.bool("isError"), true)
        XCTAssertTrue(text(result(r, 1)).contains("Hush"))
    }

    func testProbeReportsEachOutcome() async throws {
        let missing = await MCPProbe.run(server: "/nonexistent/hush-mcp", env: env)
        XCTAssertEqual(missing.level, .broken)

        let notRunning = await MCPProbe.run(server: binary, env: env)
        XCTAssertEqual(notRunning.level, .appProblem, "the server works even when the app is down")

        try startApp { _ in ["ok": true, "signed_in_as": "Test", "online": true, "unread_chats": 0] }
        let good = await MCPProbe.run(server: binary, env: env)
        XCTAssertEqual(good.level, .ok)
        XCTAssertTrue(good.message.contains("4 tools"))
    }

    func testServerNeverLaunchesTheRealAppWhenAskedNotTo() {
        setenv("HUSH_NO_LAUNCH", "1", 1)
        defer { unsetenv("HUSH_NO_LAUNCH") }
        XCTAssertFalse(ControlClient.launchAppIfNeeded(wait: 0.5, socket: AppPaths(root: URL(fileURLWithPath: home)).socketFile.path))
    }
}
