// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// The live Telegram connection: sign-in steps, the chat list, and the one open conversation.
/// Everything is event driven (TDLib pushes updates), so nothing polls and a closed popover costs nothing.
@MainActor @Observable
public final class TelegramSession {
    public enum Phase: Equatable {
        case stopped                    // not started: library or API keys missing
        case connecting
        case waitPhone
        case waitCode(String)           // where the code was sent, in words
        case waitPassword(String)       // the password hint
        case unsupported(String)
        case ready
    }

    public private(set) var phase: Phase = .stopped
    public private(set) var store = ChatStore()
    public private(set) var openChat: ChatSummary?
    public private(set) var lines: [Line] = []
    public private(set) var me = ""
    public private(set) var online = true            // false while Telegram is unreachable
    public var error: String?
    /// Called with every failed Telegram request, so the app can log and report it.
    public var onError: (@MainActor (Error) -> Void)?
    /// Fired for every incoming message in a chat that is not muted and not currently open.
    public var onIncoming: ((ChatSummary, String) -> Void)?

    public var chats: [ChatSummary] { store.sorted }
    public var unread: Int { store.unreadUnmuted }

    private var client: TDClient?
    private var keys: TelegramKeys?
    private var users: [Int64: String] = [:]
    private var quitting = false
    private let paths: AppPaths
    private let maxLines = 200
    /// How many chats TDLib is asked to hold. Every loaded chat stays in TDLib's memory, so start small.
    public static let initialChats = 20

    public init(paths: AppPaths = AppPaths()) { self.paths = paths }

    // MARK: Start / stop

    public func start() {
        guard client == nil, let keys = TelegramKeys.load(paths), let lib = TDLib.load() else { return }
        self.keys = keys
        phase = .connecting
        let c = TDClient(lib: lib)
        c.onUpdate = { [weak self] u in Task { @MainActor in self?.handle(u) } }
        client = c
        c.start()
    }

    /// Closes TDLib cleanly before the process exits (exiting with its threads running can crash). Gives up after 2 s.
    public func closeForQuit() async {
        quitting = true
        guard let c = client else { return }
        c.send(["@type": "close"])
        for _ in 0..<40 where client != nil { try? await Task.sleep(for: .milliseconds(50)) }
    }

    // MARK: Sign-in

    public func submitPhone(_ s: String) { error = nil; call(["@type": "setAuthenticationPhoneNumber", "phone_number": s.trimmingCharacters(in: .whitespaces)]) }
    public func submitCode(_ s: String) { error = nil; call(["@type": "checkAuthenticationCode", "code": s.trimmingCharacters(in: .whitespaces)]) }
    public func submitPassword(_ s: String) { error = nil; call(["@type": "checkAuthenticationPassword", "password": s]) }

    public func logOut() {
        guard let c = client else { return }
        Task { _ = try? await c.request(["@type": "logOut"]) }
        store = ChatStore(); lines = []; openChat = nil; me = ""
    }

    private func call(_ req: JSON) {
        guard let c = client else { return }
        Task { do { try await c.request(req) } catch { self.error = error.localizedDescription; self.onError?(error) } }
    }

    // MARK: Updates

    private func handle(_ u: JSON) {
        switch u.type {
        case "updateAuthorizationState": auth(u.obj("authorization_state") ?? [:])
        case "updateConnectionState": online = (u.obj("state")?.type == "connectionStateReady")
        case "updateNewMessage": incoming(u.obj("message") ?? [:])
        case "updateMessageSendSucceeded": replaceSent(u)
        case "updateMessageContent":
            if let cid = u.int("chat_id"), cid == openChat?.id, let mid = u.int("message_id"), let i = lines.firstIndex(where: { $0.id == mid }) {
                lines[i].text = MessageText.full(u.obj("new_content"))
            }
        case "updateDeleteMessages":
            if let cid = u.int("chat_id"), cid == openChat?.id, !u.bool("from_cache") {
                let gone = Set((u["message_ids"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value })
                lines.removeAll { gone.contains($0.id) }
            }
        default:
            if store.apply(u), let id = openChat?.id, let fresh = store.chats[id] { openChat = fresh }
        }
    }

    private func auth(_ s: JSON) {
        switch s.type {
        case "authorizationStateWaitTdlibParameters": sendParameters()
        case "authorizationStateWaitEncryptionKey": call(["@type": "checkDatabaseEncryptionKey", "encryption_key": dbKey()])
        case "authorizationStateWaitPhoneNumber": phase = .waitPhone
        case "authorizationStateWaitCode":
            let t = s.obj("code_info")?.obj("type")?.type ?? ""
            phase = .waitCode(t == "authenticationCodeTypeTelegramMessage" ? "Open Telegram on another device and enter the code it sent you." : "Enter the code Telegram sent you.")
        case "authorizationStateWaitPassword": phase = .waitPassword(s.str("password_hint") ?? "")
        case "authorizationStateWaitRegistration": phase = .unsupported("This phone number has no Telegram account yet. Create one in the Telegram app first.")
        case "authorizationStateReady": phase = .ready; error = nil; becameReady()
        case "authorizationStateClosed":
            client?.stop(); client = nil; phase = .stopped
            if !quitting { start() }   // after a log out TDLib closes; a fresh client serves the next sign-in
        default: break
        }
    }

    private func sendParameters() {
        guard let k = keys else { return }
        let dir = paths.tdDir.path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // One request that both old (nested `parameters`) and new (flat) TDLib versions understand; unknown fields are ignored.
        // No message or file database: history is fetched on demand, which keeps memory and disk use small.
        let base: JSON = ["api_id": k.apiId, "api_hash": k.apiHash, "database_directory": dir, "files_directory": dir,
                          "use_file_database": false, "use_chat_info_database": true, "use_message_database": false,
                          "use_secret_chats": false, "use_test_dc": false, "system_language_code": "en",
                          "device_model": "Mac", "application_version": "1.0", "enable_storage_optimizer": false,
                          "ignore_file_names": true, "system_version": ProcessInfo.processInfo.operatingSystemVersionString]
        var req = base
        req["@type"] = "setTdlibParameters"
        req["parameters"] = base.merging(["@type": "tdlibParameters"]) { $1 }
        req["database_encryption_key"] = dbKey()
        call(req)
    }

    /// Random key kept in the Keychain; it encrypts TDLib's local database (which holds the signed-in session).
    private func dbKey() -> String {
        if let d = try? Keychain.get("tdlib-db-key") { return d.base64EncodedString() }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let data = Data(bytes)
        try? Keychain.set("tdlib-db-key", data)
        return data.base64EncodedString()
    }

    private func becameReady() {
        guard let c = client else { return }
        Task {
            if let u = try? await c.request(["@type": "getMe"]) {
                me = [u.str("first_name"), u.str("last_name")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }
            _ = try? await c.request(["@type": "loadChats", "chat_list": ["@type": "chatListMain"], "limit": Self.initialChats])
        }
    }

    /// Loads older chats too; used by "show all" in the inbox. Errors mean the list is already complete.
    public func loadMoreChats(limit: Int = 100) {
        guard let c = client else { return }
        Task { _ = try? await c.request(["@type": "loadChats", "chat_list": ["@type": "chatListMain"], "limit": limit]) }
    }

    // MARK: Conversation

    public func open(_ chat: ChatSummary) {
        guard let c = client else { return }
        openChat = chat; lines = []
        Task {
            _ = try? await c.request(["@type": "openChat", "chat_id": chat.id])
            if let l = try? await history(chatId: chat.id, limit: 40), openChat?.id == chat.id {
                lines = l; markRead(chat.id)
            }
        }
    }

    public func closeChat() {
        if let c = client, let id = openChat?.id { c.send(["@type": "closeChat", "chat_id": id]) }
        openChat = nil; lines = []
    }

    private func markRead(_ chatId: Int64) {
        guard let c = client, let last = lines.last else { return }
        c.send(["@type": "viewMessages", "chat_id": chatId, "message_ids": [last.id], "force_read": true])
    }

    /// Marks a chat read without opening it, using the same `viewMessages` request as `open`.
    public func markRead(chatId: Int64) async throws {
        guard let c = client else { throw TDError(code: 0, message: "Not connected to Telegram.") }
        guard let last = try await history(chatId: chatId, limit: 1).last else { return }
        c.send(["@type": "viewMessages", "chat_id": chatId, "message_ids": [last.id], "force_read": true])
    }

    /// The last `count` incoming lines, oldest first. Reads history only, so nothing is marked read and no chat is opened.
    public func unreadLines(chatId: Int64, count: Int) async throws -> [Line] {
        guard count > 0 else { return [] }
        // Outgoing lines can sit among the unread ones, so fetch extra before filtering.
        let l = try await history(chatId: chatId, limit: count + 20)
        return Self.lastIncoming(l, count: count)
    }

    nonisolated static func lastIncoming(_ lines: [Line], count: Int) -> [Line] {
        guard count > 0 else { return [] }
        return Array(lines.filter { !$0.outgoing }.suffix(count))
    }

    /// Oldest first. Does not mark anything as read, so agents can look without side effects.
    public func history(chatId: Int64, limit: Int) async throws -> [Line] {
        guard let c = client else { throw TDError(code: 0, message: "Not connected to Telegram.") }
        var msgs: [JSON] = []
        // A cold chat first returns only a message or two; asking again fills the page.
        for attempt in 0..<3 {
            let r = try await c.request(["@type": "getChatHistory", "chat_id": chatId, "from_message_id": 0, "offset": 0, "limit": limit, "only_local": false])
            msgs = r.arr("messages")
            if msgs.count >= min(limit, 5) || attempt == 2 { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return await makeLines(Array(msgs.reversed()), chatId: chatId)
    }

    private func makeLines(_ msgs: [JSON], chatId: Int64) async -> [Line] {
        let title = store.chats[chatId]?.title ?? ""
        var out: [Line] = []
        for m in msgs {
            let sender = await senderName(m, chatTitle: title)
            out.append(Line(id: m.int("id") ?? 0, date: ChatStore.date(m) ?? .now, sender: sender, text: MessageText.full(m.obj("content")), outgoing: m.bool("is_outgoing")))
        }
        return out
    }

    private func senderName(_ m: JSON, chatTitle: String) async -> String {
        if m.bool("is_outgoing") { return "You" }
        guard let s = m.obj("sender_id"), s.type == "messageSenderUser", let uid = s.int("user_id") else { return chatTitle }
        if let n = users[uid] { return n }
        var name = chatTitle
        if let c = client, let u = try? await c.request(["@type": "getUser", "user_id": uid]) {
            let full = [u.str("first_name"), u.str("last_name")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            if !full.isEmpty { name = full }
        }
        if users.count > 200 { users.removeAll() }
        users[uid] = name
        return name
    }

    private func incoming(_ m: JSON) {
        guard let cid = m.int("chat_id") else { return }
        let outgoing = m.bool("is_outgoing")
        if cid == openChat?.id {
            Task {
                let l = await makeLines([m], chatId: cid)
                guard let line = l.first, !lines.contains(where: { $0.id == line.id }) else { return }
                lines.append(line)
                if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
                if !outgoing { markRead(cid) }
            }
        } else if !outgoing, let chat = store.chats[cid], !chat.muted {
            onIncoming?(chat, MessageText.render(m.obj("content")))
        }
    }

    private func replaceSent(_ u: JSON) {
        guard let old = u.int("old_message_id"), let m = u.obj("message"), let i = lines.firstIndex(where: { $0.id == old }) else { return }
        lines[i].id = m.int("id") ?? old
    }

    // MARK: Sending

    /// Sends plain text. Used by the compose box and, after approval, by agents.
    public func send(_ text: String, to chatId: Int64) async throws {
        guard let c = client else { throw TDError(code: 0, message: "Not connected to Telegram.") }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let r = try await c.request(["@type": "sendMessage", "chat_id": chatId,
                                     "input_message_content": ["@type": "inputMessageText", "text": ["@type": "formattedText", "text": t]] as JSON])
        if chatId == openChat?.id, let id = r.int("id"), !lines.contains(where: { $0.id == id }) {
            lines.append(Line(id: id, date: ChatStore.date(r) ?? .now, sender: "You", text: t, outgoing: true))
        }
    }

    // MARK: Demo (screenshots only)

    public func loadDemo(chats: [ChatSummary], unread: Int, lines: [Line], open: ChatSummary?) {
        store.replace(chats, unreadUnmuted: unread); phase = .ready; me = "Demo"; openChat = open; self.lines = lines
    }
}
