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

    func testTDLibVersionCheck() {
        XCTAssertTrue(TDLib.versionAtLeast("1.8.69", "1.8.60"))
        XCTAssertTrue(TDLib.versionAtLeast("1.8.60", "1.8.60"))
        XCTAssertTrue(TDLib.versionAtLeast("1.9.0", "1.8.60"))
        XCTAssertFalse(TDLib.versionAtLeast("1.8.0", "1.8.60"))   // the old Homebrew build Telegram rejects
        XCTAssertFalse(TDLib.versionAtLeast("0.9", "1.8.60"))
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
        guard let lib = TDLib.load() else { throw XCTSkip("A current TDLib is not installed") }
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

final class ShortcutTests: XCTestCase {
    func testHotKeySlotIdsAreDistinctAndOpenKeepsItsOriginalId() {
        XCTAssertEqual(HotKeySlot.open.rawValue, 1)   // the id the single-slot HotKey always used
        XCTAssertEqual(Set(HotKeySlot.allCases.map(\.rawValue)).count, HotKeySlot.allCases.count)
        XCTAssertEqual(HotKeySlot(rawValue: 2), .stack)
        XCTAssertNil(HotKeySlot(rawValue: 0))
    }

    func testDisplayAndValidity() {
        XCTAssertEqual(Shortcut.default.display, "⌃⌥H")
        XCTAssertTrue(Shortcut.default.isValid)
        XCTAssertFalse(Shortcut(keyCode: 4, modifiers: Shortcut.shift).isValid)   // shift alone would fire while typing
        XCTAssertFalse(Shortcut(keyCode: 4, modifiers: 0).isValid)
        XCTAssertFalse(Shortcut(keyCode: 999, modifiers: Shortcut.cmd).isValid)   // unknown key
    }

    func testCocoaFlagConversion() {
        let flags: UInt = (1 << 20) | (1 << 19) | (1 << 17)   // command, option, shift
        let s = Shortcut(keyCode: 49, cocoaFlags: flags)
        XCTAssertEqual(s.display, "⌥⇧⌘Space")
    }

    func testCodable() throws {
        let data = try JSONEncoder().encode(Shortcut.default)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: data), .default)
    }

    func testReturnKeySendsAndModifiedReturnStartsALine() {
        XCTAssertEqual(ComposeKey.action(shift: false, option: false, control: false), .send)
        XCTAssertEqual(ComposeKey.action(shift: true, option: false, control: false), .newline)
        XCTAssertEqual(ComposeKey.action(shift: false, option: true, control: false), .newline)
        XCTAssertEqual(ComposeKey.action(shift: false, option: false, control: true), .newline)
    }

    func testTabSwitchesChatsUnlessComposingOrModified() {
        XCTAssertTrue(ComposeKey.switchesChat(keyCode: 48, option: false, control: false, command: false, composing: false))
        XCTAssertFalse(ComposeKey.switchesChat(keyCode: 48, option: false, control: false, command: false, composing: true))
        XCTAssertFalse(ComposeKey.switchesChat(keyCode: 48, option: true, control: false, command: false, composing: false))
        XCTAssertFalse(ComposeKey.switchesChat(keyCode: 48, option: false, control: true, command: false, composing: false))
        XCTAssertFalse(ComposeKey.switchesChat(keyCode: 48, option: false, control: false, command: true, composing: false))
        XCTAssertFalse(ComposeKey.switchesChat(keyCode: 36, option: false, control: false, command: false, composing: false))
    }

    func testBannerPolicyDefaultsToFavorites() {
        XCTAssertTrue(BannerPolicy.shouldShow(enabled: true, favoritesOnly: true, isFavorite: true))
        XCTAssertFalse(BannerPolicy.shouldShow(enabled: true, favoritesOnly: true, isFavorite: false))
        XCTAssertTrue(BannerPolicy.shouldShow(enabled: true, favoritesOnly: false, isFavorite: false), "all chats when enabled")
        XCTAssertFalse(BannerPolicy.shouldShow(enabled: false, favoritesOnly: false, isFavorite: true), "off means off")
    }

    func testChatListFilterTabsSearchAndOlder() {
        let now = Date()
        let old = now.addingTimeInterval(-30 * 86_400)
        let chats = [
            ChatSummary(id: 1, title: "Mara", lastText: "dinner at 7", lastDate: now, unread: 2),
            ChatSummary(id: 2, title: "Old friend", lastText: "hello", lastDate: old),
            ChatSummary(id: 3, title: "Starred old", lastText: "x", lastDate: old),
            ChatSummary(id: 4, title: "Muted team", lastText: "news", lastDate: now, unread: 5, muted: true),
        ]
        let fav: (Int64) -> Bool = { $0 == 3 }
        let all = ChatListFilter.apply(chats, tab: .all, isFavorite: fav, now: now)
        XCTAssertEqual(all.shown.map(\.id), [3, 1, 4]); XCTAssertEqual(all.hidden, 1, "quiet chats hide behind show older")
        XCTAssertEqual(ChatListFilter.apply(chats, tab: .all, showOlder: true, isFavorite: fav, now: now).shown.count, 4)
        XCTAssertEqual(ChatListFilter.apply(chats, tab: .unread, isFavorite: fav, now: now).shown.map(\.id), [1, 4])
        XCTAssertEqual(ChatListFilter.apply(chats, tab: .favorites, isFavorite: fav, now: now).shown.map(\.id), [3])
        let found = ChatListFilter.apply(chats, tab: .all, query: "old", isFavorite: fav, now: now)
        XCTAssertEqual(found.shown.map(\.id), [3, 2], "search reaches old chats"); XCTAssertEqual(found.hidden, 0)
        XCTAssertEqual(ChatListFilter.apply(chats, tab: .all, query: "DINNER", isFavorite: fav, now: now).shown.map(\.id), [1], "matches the last message, any case")
        XCTAssertEqual(ChatListFilter.unreadBadge(chats), 1, "muted chats do not count")
    }

    func testChatNavigationStepFollowsDisplayedOrderWithoutWrap() {
        let chats = [1, 2, 3].map { ChatSummary(id: Int64($0), title: "c\($0)") }
        XCTAssertEqual(ChatNavigation.step(chats, from: 1, forward: true, wrap: false)?.id, 2)
        XCTAssertEqual(ChatNavigation.step(chats, from: 3, forward: false, wrap: false)?.id, 2)
        XCTAssertEqual(ChatNavigation.step(chats, from: 3, forward: true, wrap: false)?.id, 3, "no wrap at the end")
        XCTAssertEqual(ChatNavigation.step(chats, from: 1, forward: false, wrap: false)?.id, 1, "no wrap at the start")
        // Fed with the filter's output, favorites come first.
        let shown = ChatListFilter.apply(chats, tab: .all, showOlder: true, isFavorite: { $0 == 3 }).shown
        XCTAssertEqual(ChatNavigation.step(shown, from: 3, forward: true, wrap: false)?.id, 1)
    }

    func testChatNavigationStepWrapsAndHandlesMissingCurrent() {
        let chats = [1, 2, 3].map { ChatSummary(id: Int64($0), title: "c\($0)") }
        XCTAssertEqual(ChatNavigation.step(chats, from: 3, forward: true, wrap: true)?.id, 1)
        XCTAssertEqual(ChatNavigation.step(chats, from: 1, forward: false, wrap: true)?.id, 3)
        XCTAssertEqual(ChatNavigation.step(chats, from: nil, forward: true, wrap: true)?.id, 1)
        XCTAssertEqual(ChatNavigation.step(chats, from: nil, forward: false, wrap: true)?.id, 3)
        XCTAssertEqual(ChatNavigation.step(chats, from: 99, forward: true, wrap: false)?.id, 1, "unknown id acts like nil")
    }

    func testChatNavigationStepEmptyAndSingleList() {
        let one = [ChatSummary(id: 7, title: "only")]
        for wrap in [false, true] {
            for forward in [false, true] {
                XCTAssertNil(ChatNavigation.step([], from: nil, forward: forward, wrap: wrap))
                XCTAssertNil(ChatNavigation.step([], from: 7, forward: forward, wrap: wrap))
                XCTAssertEqual(ChatNavigation.step(one, from: 7, forward: forward, wrap: wrap)?.id, 7)
                XCTAssertEqual(ChatNavigation.step(one, from: nil, forward: forward, wrap: wrap)?.id, 7)
            }
        }
    }

    func testChatListFilterPinsFavoritesFirst() {
        let now = Date()
        let old = now.addingTimeInterval(-30 * 86_400)
        func chat(_ id: Int64, _ date: Date, unread: Int = 0, muted: Bool = false) -> ChatSummary {
            ChatSummary(id: id, title: "Chat \(id)", lastText: "", lastDate: date, unread: unread, muted: muted)
        }
        let chats = [chat(1, now), chat(2, old), chat(3, now), chat(4, now)]   // non-fav newest, fav old, non-fav, fav
        func ids(_ cs: [ChatSummary], tab: ChatTab = .all, query: String = "", showOlder: Bool = false, favs: Set<Int64>? = nil) -> (shown: [Int64], hidden: Int) {
            let f = favs ?? [2, 4]
            let r = ChatListFilter.apply(cs, tab: tab, query: query, showOlder: showOlder, isFavorite: { f.contains($0) }, now: now)
            return (r.shown.map(\.id), r.hidden)
        }
        // R1, R2, R7: favorites first in input order, non-favorites after in input order; the old favorite is shown and not counted hidden
        let all = ids(chats)
        XCTAssertEqual(all.shown, [2, 4, 1, 3]); XCTAssertEqual(all.hidden, 0)
        // R3: toggling the predicate moves the chat at once
        XCTAssertEqual(ids(chats, favs: [2, 4, 3]).shown, [2, 3, 4, 1])
        XCTAssertEqual(ids(chats, favs: [4]).shown, [4, 1, 3], "unstarred old chat falls back to hidden older")
        XCTAssertEqual(ids(chats, favs: [4]).hidden, 1)
        // R4: a new message in a non-favorite does not displace favorites; in a favorite it reorders only among favorites
        XCTAssertEqual(ids([chats[2], chats[0], chats[1], chats[3]]).shown, [2, 4, 3, 1])
        XCTAssertEqual(ids([chats[3], chats[0], chats[1], chats[2]]).shown, [4, 2, 1, 3])
        // R5: Unread tab pins favorites; Favorites tab keeps input order
        let unread = [chat(1, now, unread: 1), chat(2, old, unread: 1), chat(3, now, unread: 1)]
        XCTAssertEqual(ids(unread, tab: .unread, favs: [2]).shown, [2, 1, 3])
        XCTAssertEqual(ids(chats, tab: .favorites).shown, [2, 4])
        XCTAssertEqual(ids([chats[3], chats[1]], tab: .favorites).shown, [4, 2])
        // R6: search keeps favorites first
        XCTAssertEqual(ids(chats, query: "chat").shown, [2, 4, 1, 3])
        // muted favorites are still pinned
        let muted = [chat(1, now), chat(2, now, muted: true)]
        XCTAssertEqual(ids(muted, favs: [2]).shown, [2, 1])
        // R7 with show older on
        XCTAssertEqual(ids(chats, showOlder: true).shown, [2, 4, 1, 3])
    }

    func testPopoverFooterCountsMatchSharedFilter() {
        // InboxView shows "\(shown.count) of \(chats.count)" while hidden > 0, else "\(shown.count) chats"; the old inline rule was hidden = total - visible.
        let now = Date()
        let old = now.addingTimeInterval(-30 * 86_400)
        let chats = [
            ChatSummary(id: 1, title: "a", lastText: "", lastDate: now),
            ChatSummary(id: 2, title: "b", lastText: "", lastDate: old),                 // quiet, hidden
            ChatSummary(id: 3, title: "c", lastText: "", lastDate: old),                 // old favorite, shown
            ChatSummary(id: 4, title: "d", lastText: "", lastDate: old, unread: 1),      // old unread, shown
            ChatSummary(id: 5, title: "e", lastText: "", lastDate: nil),                 // never active, hidden
        ]
        let fav: (Int64) -> Bool = { $0 == 3 }
        let r = ChatListFilter.apply(chats, tab: .all, showOlder: false, isFavorite: fav, now: now)
        XCTAssertEqual(r.shown.map(\.id), [3, 1, 4])
        XCTAssertEqual(r.hidden, chats.count - r.shown.count, "footer 'N of M' and the 'Show N older' button agree")
        XCTAssertEqual(r.hidden, 2, "the favorite is never counted as hidden")
        let more = ChatListFilter.apply(chats, tab: .all, showOlder: true, isFavorite: fav, now: now)
        XCTAssertEqual(more.shown.count, chats.count); XCTAssertEqual(more.hidden, 0, "'Show active only' state: footer drops to plain count")
    }

    func testReportsNeverContainPersonalDetails() throws {
        let raw = "failed at /Users/mehdi/Library/Application Support/Hush/x for mehdi@example.com, +98 912 345 6789, bot 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw, https://x.org/a?token=secret, key a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
        let s = Privacy.scrub(raw, home: "/Users/mehdi", user: "mehdi", host: "mehdis-mac.local")
        for leak in ["mehdi", "example.com", "912", "AAHdq", "secret", "a1b2c3d4"] { XCTAssertFalse(s.contains(leak), "leaked \(leak): \(s)") }
        XCTAssertTrue(s.contains("Application Support/Hush/x"), "useful paths survive")

        let p = AppProblem.from(TDError(code: 400, message: "Chat not found"), area: "Telegram")
        XCTAssertEqual(p.area, "Telegram"); XCTAssertEqual(p.title, "Telegram couldn't do that")
        XCTAssertEqual(AppProblem.from(URLError(.timedOut), area: "Agents").title, "Couldn't reach the internet")
        struct Odd: Error {}
        XCTAssertEqual(AppProblem.from(Odd(), area: "Login Items").title, "Something went wrong in Login Items")
        let url = try XCTUnwrap(AppProblem(area: "Telegram", title: "t", hint: "h", detail: "d").issueURL(repo: "a/b", app: "Hush 1 (abc)", system: "macOS", log: "see /Users/bob/x"))
        XCTAssertFalse(url.absoluteString.contains("bob")); XCTAssertTrue(url.absoluteString.contains("macOS"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hush-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var log = ErrorLog(url: dir.appendingPathComponent("errors.log")); log.limit = 100
        for i in 0..<20 { log.append("entry \(i) \(String(repeating: "x", count: 20))\n") }
        XCTAssertLessThanOrEqual(log.text.count, 100); XCTAssertTrue(log.text.contains("entry 19"))
    }

    func testUpdateProblemsAreFriendlyAndLogged() {
        let build = UpdateProblem.from(UpdateError.buildFailed("error: cannot find 'Foo' in scope"))
        XCTAssertEqual(build.title, "The new version couldn't be built")
        XCTAssertTrue(build.hint.contains("untouched")); XCTAssertTrue(build.detail.contains("Foo"), "technical text goes to the log")
        XCTAssertFalse(build.title.contains("Foo"))

        let offline = UpdateProblem.from(UpdateError.buildFailed("fatal: unable to access 'https://github.com/x.git/': Could not resolve host: github.com"))
        XCTAssertEqual(offline.title, "Couldn't reach GitHub", "a failed clone is a network problem, not a build problem")
        XCTAssertEqual(UpdateProblem.from(URLError(.notConnectedToInternet)).title, "Couldn't reach GitHub")
        XCTAssertEqual(UpdateProblem.from(UpdateError.rateLimited).title, "GitHub is limiting requests")
        XCTAssertTrue(UpdateProblem.from(ShellError.toolNotFound("git")).hint.contains("xcode-select"))
        XCTAssertTrue(UpdateProblem.from(UpdateError.verifyFailed("It didn't start correctly.")).hint.contains("Nothing was replaced"))
        struct Odd: Error {}
        XCTAssertEqual(UpdateProblem.from(Odd()).title, "Something went wrong while updating", "unknown errors still get a plain message")

        let entry = build.logEntry(step: "Building", app: "Hush 0.1.3 (abc1234)", system: "macOS 15", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(entry.hasPrefix("[1970-01-01T00:00:00Z] FAILED in Update during \"Building\""))
        XCTAssertTrue(entry.contains("Hush 0.1.3 (abc1234)")); XCTAssertEqual(entry.split(separator: "\n").count, 3, "multi-line detail stays on one line")
        XCTAssertTrue(build.report(step: "Building", system: "b").contains("Step: Building"))
        let url = build.issueURL(repo: "kalahroudi/hush", step: "Building", app: "a", system: "b", log: String(repeating: "x ", count: 9000))
        XCTAssertEqual(url?.host, "github.com"); XCTAssertEqual(url?.path, "/kalahroudi/hush/issues/new")
        XCTAssertLessThan(url?.absoluteString.count ?? .max, 8000, "stays within GitHub's URL limit")
    }
}
