// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The two values Telegram requires from every client app. Free, from https://my.telegram.org/apps.
/// They identify the app, not the account, so they live in a private file (0600) and detection never prompts.
public struct TelegramKeys: Codable, Equatable, Sendable {
    public var apiId: Int
    public var apiHash: String
    public static let pageURL = "https://my.telegram.org/apps"

    public static func parse(id: String, hash: String) -> TelegramKeys? {
        let h = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let i = Int(id.trimmingCharacters(in: .whitespacesAndNewlines)), i > 0,
              h.count == 32, h.allSatisfy({ $0.isHexDigit }) else { return nil }
        return TelegramKeys(apiId: i, apiHash: h)
    }

    public static func load(_ paths: AppPaths = AppPaths()) -> TelegramKeys? {
        guard let d = try? Data(contentsOf: paths.apiKeysFile) else { return nil }
        return try? JSONDecoder().decode(TelegramKeys.self, from: d)
    }

    public func save(_ paths: AppPaths = AppPaths()) throws {
        try paths.ensureDirectories()
        try JSONEncoder().encode(self).write(to: paths.apiKeysFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.apiKeysFile.path)
    }
}

public struct ChatSummary: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var lastText: String
    public var lastDate: Date?
    public var unread: Int
    public var muted: Bool
    public var order: Int64
    public init(id: Int64, title: String, lastText: String = "", lastDate: Date? = nil, unread: Int = 0, muted: Bool = false, order: Int64 = 0) {
        self.id = id; self.title = title; self.lastText = lastText; self.lastDate = lastDate; self.unread = unread; self.muted = muted; self.order = order
    }
}

/// One line of a conversation: time, who, text. Nothing else survives.
public struct Line: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var date: Date
    public var sender: String
    public var text: String
    public var outgoing: Bool
    public init(id: Int64, date: Date, sender: String, text: String, outgoing: Bool) {
        self.id = id; self.date = date; self.sender = sender; self.text = text; self.outgoing = outgoing
    }
}

/// Turns any Telegram message content into one plain line. Media never downloads; it becomes a bracketed marker.
public enum MessageText {
    public static func render(_ content: JSON?) -> String {
        guard let c = content else { return "" }
        func caption(_ marker: String) -> String {
            let t = c.obj("caption")?.str("text") ?? ""
            return t.isEmpty ? marker : "\(marker) \(oneLine(t))"
        }
        switch c.type {
        case "messageText": return oneLine(c.obj("text")?.str("text") ?? "")
        case "messagePhoto": return caption("[photo]")
        case "messageVideo": return caption("[video]")
        case "messageAnimation": return caption("[gif]")
        case "messageAudio": return caption("[audio]")
        case "messageVoiceNote": return caption("[voice note]")
        case "messageVideoNote": return "[video note]"
        case "messageDocument": return caption(marker("file", c.obj("document")?.str("file_name")))
        case "messageSticker": return marker("sticker", c.obj("sticker")?.str("emoji"))
        case "messageLocation", "messageVenue": return "[location]"
        case "messageContact": return "[contact]"
        case "messagePoll": return marker("poll", c.obj("poll")?.str("question").map(oneLine))
        case "messageCall": return "[call]"
        case "messagePinMessage": return "[pinned a message]"
        case "messageChatJoinByLink", "messageChatAddMembers", "messageChatJoinByRequest": return "[joined]"
        case "messageChatDeleteMember": return "[left]"
        case "": return ""
        default: return "[service message]"
        }
    }

    static func marker(_ kind: String, _ detail: String?) -> String {
        guard let d = detail, !d.isEmpty else { return "[\(kind)]" }
        return "[\(kind) \(d)]"
    }

    /// Newlines become spaces in previews; the thread view keeps the full text via `lines`.
    public static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Full text for a thread line: keeps line breaks for plain text, markers for media.
    public static func full(_ content: JSON?) -> String {
        if let c = content, c.type == "messageText" { return c.obj("text")?.str("text") ?? "" }
        return render(content)
    }
}

/// The chat list as a pure value that applies TDLib updates. No I/O, so it is unit tested.
public struct ChatStore: Sendable {
    public private(set) var chats: [Int64: ChatSummary] = [:]
    public private(set) var unreadUnmuted = 0
    public init() {}

    public var sorted: [ChatSummary] {
        chats.values.filter { $0.order > 0 }.sorted { $0.order > $1.order }
    }

    /// Applies one update. Returns true when something visible changed.
    @discardableResult
    public mutating func apply(_ u: JSON) -> Bool {
        switch u.type {
        case "updateNewChat":
            guard let c = u.obj("chat"), let id = c.int("id") else { return false }
            var s = ChatSummary(id: id, title: c.str("title") ?? "")
            s.unread = Int(c.int("unread_count") ?? 0)
            s.muted = Self.isMuted(c.obj("notification_settings"))
            if let m = c.obj("last_message") { s.lastText = MessageText.render(m.obj("content")); s.lastDate = Self.date(m) }
            s.order = Self.mainOrder(c.arr("positions"))
            chats[id] = s; return true
        case "updateChatLastMessage":
            guard let id = u.int("chat_id"), var s = chats[id] else { return false }
            if let m = u.obj("last_message") { s.lastText = MessageText.render(m.obj("content")); s.lastDate = Self.date(m) }
            if u["positions"] != nil { s.order = Self.mainOrder(u.arr("positions")) }
            chats[id] = s; return true
        case "updateChatPosition":
            guard let id = u.int("chat_id"), var s = chats[id], let p = u.obj("position"), p.obj("list")?.type == "chatListMain" else { return false }
            s.order = p.int("order") ?? 0; chats[id] = s; return true
        case "updateChatReadInbox":
            guard let id = u.int("chat_id"), var s = chats[id] else { return false }
            s.unread = Int(u.int("unread_count") ?? 0); chats[id] = s; return true
        case "updateChatNotificationSettings":
            guard let id = u.int("chat_id"), var s = chats[id] else { return false }
            s.muted = Self.isMuted(u.obj("notification_settings")); chats[id] = s; return true
        case "updateChatTitle":
            guard let id = u.int("chat_id"), var s = chats[id] else { return false }
            s.title = u.str("title") ?? s.title; chats[id] = s; return true
        case "updateUnreadChatCount":
            guard u.obj("chat_list")?.type == "chatListMain" else { return false }
            unreadUnmuted = Int(u.int("unread_unmuted_count") ?? 0); return true
        default: return false
        }
    }

    public mutating func replace(_ list: [ChatSummary], unreadUnmuted: Int) {
        chats = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) }); self.unreadUnmuted = unreadUnmuted
    }

    static func isMuted(_ n: JSON?) -> Bool {
        guard let n else { return false }
        return !n.bool("use_default_mute_for") && (n.int("mute_for") ?? 0) > 0
    }
    static func mainOrder(_ positions: [JSON]) -> Int64 {
        positions.first { $0.obj("list")?.type == "chatListMain" }?.int("order") ?? 0
    }
    public static func date(_ message: JSON) -> Date? { message.int("date").map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

/// How an agent names a chat: a numeric id or part of the title.
public enum ChatMatch: Equatable {
    case one(ChatSummary), many([String]), none

    public static func resolve(_ query: String, in chats: [ChatSummary]) -> ChatMatch {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let id = Int64(q), let c = chats.first(where: { $0.id == id }) { return .one(c) }
        let lower = q.lowercased()
        let exact = chats.filter { $0.title.lowercased() == lower }
        if exact.count == 1 { return .one(exact[0]) }
        let hits = chats.filter { $0.title.lowercased().contains(lower) }
        if hits.count == 1 { return .one(hits[0]) }
        return hits.isEmpty ? .none : .many(hits.map(\.title))
    }
}
