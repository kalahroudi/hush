import XCTest
@testable import HushKit

final class KitTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(Version.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(Version.isNewer("v1.0.0", than: "1.0.0-beta.2"))
        XCTAssertFalse(Version.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Version.isNewer("garbage", than: "1.0.0"))
    }

    func testChecksumLookup() {
        let sums = "abc123  Hush-0.1.0.dmg\ndef456 *other.dmg\n"
        XCTAssertEqual(UpdateChecker.checksum(in: sums, for: "Hush-0.1.0.dmg"), "abc123")
        XCTAssertEqual(UpdateChecker.checksum(in: sums, for: "other.dmg"), "def456")
        XCTAssertNil(UpdateChecker.checksum(in: sums, for: "missing.dmg"))
    }

    func testCompareDecision() throws {
        let ahead = Data(#"{"status":"ahead","ahead_by":1,"commits":[{"commit":{"message":"Fix a thing\n\nbody"}}]}"#.utf8)
        guard case .available(let info) = try UpdateChecker.decide(compareJSON: ahead, head: "deadbeef") else { return XCTFail("expected available") }
        XCTAssertEqual(info.summaries, ["Fix a thing"])
        XCTAssertEqual(try UpdateChecker.decide(compareJSON: Data(#"{"status":"identical"}"#.utf8), head: "x"), .upToDate)
    }

    func testSwapScriptRollsBack() {
        XCTAssertTrue(UpdateSwap.script.contains("restored"))
    }

    func testAgentConfigRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"other":1,"mcpServers":{"keep":{"command":"x"}}}"#.utf8).write(to: url)
        try AgentIntegrations.jsonInstall(at: url, command: "/Applications/Hush.app/Contents/MacOS/hush-mcp")
        XCTAssertEqual(AgentIntegrations.jsonCommand(at: url), "/Applications/Hush.app/Contents/MacOS/hush-mcp")
        try AgentIntegrations.jsonRemove(at: url)
        XCTAssertNil(AgentIntegrations.jsonCommand(at: url))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNotNil((root?["mcpServers"] as? [String: Any])?["keep"], "other servers must survive")
        XCTAssertEqual(root?["other"] as? Int, 1)
    }

    func testSetupStateWithNothingMissingIsReady() {
        XCTAssertTrue(SetupState(items: []).ready)
    }
}

// MARK: Hush

final class TelegramTests: XCTestCase {
    func testMessageRendering() {
        XCTAssertEqual(MessageText.render(["@type": "messageText", "text": ["text": "hi\nthere"]]), "hi there")
        XCTAssertEqual(MessageText.render(["@type": "messagePhoto", "caption": ["text": ""]]), "[photo]")
        XCTAssertEqual(MessageText.render(["@type": "messagePhoto", "caption": ["text": "roof"]]), "[photo] roof")
        XCTAssertEqual(MessageText.render(["@type": "messageSticker", "sticker": ["emoji": "😀"]]), "[sticker 😀]")
        XCTAssertEqual(MessageText.render(["@type": "messageDocument", "document": ["file_name": "a.pdf"]]), "[file a.pdf]")
        XCTAssertEqual(MessageText.render(["@type": "messageChatChangeTitle"]), "[service message]")
        XCTAssertEqual(MessageText.full(["@type": "messageText", "text": ["text": "a\nb"]]), "a\nb")
    }

    func testChatStoreAppliesUpdates() {
        var s = ChatStore()
        let chat: JSON = ["@type": "updateNewChat", "chat": ["id": 7, "title": "Mara", "unread_count": 2,
            "last_message": ["date": 1_700_000_000, "content": ["@type": "messageText", "text": ["text": "ok"]]],
            "positions": [["list": ["@type": "chatListMain"], "order": "500"]],
            "notification_settings": ["use_default_mute_for": false, "mute_for": 0]]]
        XCTAssertTrue(s.apply(chat))
        XCTAssertEqual(s.sorted.first?.lastText, "ok")
        XCTAssertEqual(s.chats[7]?.order, 500)
        s.apply(["@type": "updateChatReadInbox", "chat_id": 7, "unread_count": 0])
        XCTAssertEqual(s.chats[7]?.unread, 0)
        s.apply(["@type": "updateChatNotificationSettings", "chat_id": 7, "notification_settings": ["use_default_mute_for": false, "mute_for": 3600]])
        XCTAssertEqual(s.chats[7]?.muted, true)
        s.apply(["@type": "updateChatPosition", "chat_id": 7, "position": ["list": ["@type": "chatListMain"], "order": "0"]])
        XCTAssertTrue(s.sorted.isEmpty)   // removed from the main list
        s.apply(["@type": "updateUnreadChatCount", "chat_list": ["@type": "chatListMain"], "unread_unmuted_count": 3])
        XCTAssertEqual(s.unreadUnmuted, 3)
        XCTAssertFalse(s.apply(["@type": "updateChatReadInbox", "chat_id": 99, "unread_count": 1]))
    }

    func testChatMatching() {
        let list = [ChatSummary(id: 1, title: "Mara"), ChatSummary(id: 2, title: "Mara Work"), ChatSummary(id: 3, title: "Dad")]
        XCTAssertEqual(ChatMatch.resolve("3", in: list), .one(list[2]))
        XCTAssertEqual(ChatMatch.resolve("mara", in: list), .one(list[0]))      // exact beats partial
        XCTAssertEqual(ChatMatch.resolve("ma", in: list), .many(["Mara", "Mara Work"]))
        XCTAssertEqual(ChatMatch.resolve("zed", in: list), .none)
    }

    func testApiKeyValidation() {
        XCTAssertNotNil(TelegramKeys.parse(id: " 12345 ", hash: "0123456789ABCDEF0123456789abcdef"))
        XCTAssertNil(TelegramKeys.parse(id: "abc", hash: "0123456789abcdef0123456789abcdef"))
        XCTAssertNil(TelegramKeys.parse(id: "1", hash: "short"))
        XCTAssertNil(TelegramKeys.parse(id: "1", hash: String(repeating: "z", count: 32)))
    }

    func testApiKeysRoundTripIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hush-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AppPaths(root: dir)
        let keys = TelegramKeys(apiId: 42, apiHash: String(repeating: "a", count: 32))
        try keys.save(paths)
        XCTAssertEqual(TelegramKeys.load(paths), keys)
        let perms = try FileManager.default.attributesOfItem(atPath: paths.apiKeysFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testApprovalOnlyAllowsExplicitSend() {
        XCTAssertTrue(Approval.allowed(output: "button returned:Send, gave up:false"))
        XCTAssertFalse(Approval.allowed(output: "button returned:Send, gave up:true"))
        XCTAssertFalse(Approval.allowed(output: "button returned:Deny, gave up:false"))
        XCTAssertFalse(Approval.allowed(output: ""))
        XCTAssertTrue(Approval.script(chat: "A \"b\"", text: "x\ny").contains("A \\\"b\\\""))
    }

    func testControlSocketRoundTrip() async throws {
        let path = "/tmp/hush-t-\(getpid()).sock"
        let server = ControlServer(path: path) { req in ["ok": true, "echo": req["n"] ?? 0] }
        try server.start()
        defer { server.stop() }
        let res = try ControlClient.call(["n": 5], socket: path, timeout: 5)
        XCTAssertEqual(res.int("echo"), 5)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        server.stop()
        XCTAssertThrowsError(try ControlClient.call(["n": 1], socket: path, timeout: 2))
    }

    func testSetupListsKeysStep() {
        let s = SetupState.detect()
        XCTAssertTrue(s.items.contains { $0.id == "keys" })
        XCTAssertTrue(s.items.contains { $0.id == "tdlib" })
    }
}

final class TDLibTests: XCTestCase {
    /// Loads the real library when present, reaches the parameters state, and closes cleanly. Skipped where TDLib is not installed.
    func testClientReachesParametersAndCloses() async throws {
        guard let lib = TDLib() else { throw XCTSkip("TDLib is not installed") }
        let client = TDClient(lib: lib)
        let params = expectation(description: "wait parameters")
        let closed = expectation(description: "closed")
        params.assertForOverFulfill = false
        client.onUpdate = { u in
            guard u.type == "updateAuthorizationState" else { return }
            switch u.obj("authorization_state")?.type {
            case "authorizationStateWaitTdlibParameters": params.fulfill()
            case "authorizationStateClosed": closed.fulfill()
            default: break
            }
        }
        client.start()
        await fulfillment(of: [params], timeout: 10)
        client.send(["@type": "close"])
        await fulfillment(of: [closed], timeout: 10)
        client.stop()
    }
}
