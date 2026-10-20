// SPDX-License-Identifier: Apache-2.0

import Foundation
import HushKit

typealias Args = [String: Any]

struct Tool {
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    let handler: @Sendable (Args) async throws -> String
    var readOnly: Bool { name != "hush_send" }

    var definition: [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": true] as [String: Any]]
    }
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func prop(_ type: String, _ desc: String, enumValues: [String]? = nil) -> [String: Any] {
    var p: [String: Any] = ["type": type, "description": desc]
    if let e = enumValues { p["enum"] = e }
    return p
}

private func json<T: Encodable>(_ value: T) throws -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try enc.encode(value), as: UTF8.self)
}

func requireString(_ a: Args, _ key: String) throws -> String {
    guard let v = a[key] as? String, !v.isEmpty else { throw ToolError(message: "Missing required argument: \(key)") }
    return v
}

/// Asks the running Hush app (starting it quietly if needed). Hush owns the Telegram session; this process only relays.
private func ask(_ req: JSON) throws -> JSON {
    guard ControlClient.launchAppIfNeeded() else {
        throw ToolError(message: "Hush is not installed or could not start. Install it from github.com/kalahroudi/hush and open it once.")
    }
    let res = try ControlClient.call(req)
    if res.bool("ok") { return res }
    throw ToolError(message: res.str("error") ?? "Hush could not do that.")
}

private func compact(_ o: JSON) throws -> String {
    var o = o; o.removeValue(forKey: "ok")
    return String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

// Tools mirror what a person sees in Hush: chats, plain-text lines, and one way to send.
let allTools: [Tool] = [
    Tool(name: "hush_status", description: "Read-only. Whether Hush is signed in to Telegram, who as, and how many chats have unread messages.",
         properties: [:], required: []) { _ in try compact(try ask(["op": "status"])) },

    Tool(name: "hush_list_chats", description: "Read-only. List Telegram chats, newest first, with id, title, unread count, muted flag and the last line. Does not mark anything as read.",
         properties: ["unread_only": prop("boolean", "Only chats with unread messages."), "limit": prop("integer", "Maximum chats, default 30, at most 100.")],
         required: []) { a in
        var r: JSON = ["op": "chats"]
        if let u = a["unread_only"] as? Bool { r["unread_only"] = u }
        if let l = a["limit"] as? Int { r["limit"] = l }
        return try compact(try ask(r))
    },

    Tool(name: "hush_read", description: "Read-only. Read the latest plain-text messages of one chat, oldest first. Media appears as markers such as [photo]. Does not mark anything as read.",
         properties: ["chat": prop("string", "Chat id from hush_list_chats, or part of the chat title."), "limit": prop("integer", "Maximum messages, default 30, at most 100.")],
         required: ["chat"]) { a in
        var r: JSON = ["op": "read", "chat": try requireString(a, "chat")]
        if let l = a["limit"] as? Int { r["limit"] = l }
        return try compact(try ask(r))
    },

    Tool(name: "hush_send", description: "Sends a plain-text Telegram message AS THE USER. Every call shows a native approval dialog with the full text, and the user may deny it; if denied, do not retry. Ask the user what to send before calling.",
         properties: ["chat": prop("string", "Chat id from hush_list_chats, or part of the chat title."), "text": prop("string", "The exact message text.")],
         required: ["chat", "text"]) { a in
        let res = try ask(["op": "send", "chat": try requireString(a, "chat"), "text": try requireString(a, "text")])
        return "Sent to \(res.str("sent_to") ?? "the chat")."
    },
]
