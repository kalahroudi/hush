// SPDX-License-Identifier: Apache-2.0

import Foundation
import HushKit

/// Answers the MCP server's requests on behalf of the signed-in session. Reading is a setting; sending always asks the user.
enum AgentBridge {
    private static func fail(_ m: String) -> JSON { ["ok": false, "error": m] }

    static func handle(_ req: JSON) async -> JSON {
        let op = req.str("op") ?? ""
        if op == "ping" { return ["ok": true] }
        return await run(op, req)
    }

    @MainActor private static func run(_ op: String, _ req: JSON) async -> JSON {
        let model = AppModel.shared
        let s = model.session
        guard s.phase == .ready else { return fail("Hush is not signed in to Telegram. Ask the user to open Hush from the menu bar and sign in.") }
        switch op {
        case "status":
            return ["ok": true, "signed_in_as": s.me, "online": s.online, "unread_chats": s.unread]
        case "chats":
            guard Prefs.shared.agentsCanRead else { return fail("The user has turned off agent access to chats in Hush settings.") }
            let only = req.bool("unread_only")
            let limit = Int(req.int("limit") ?? 30)
            let list = s.chats.filter { !only || $0.unread > 0 }.prefix(max(1, min(limit, 100))).map { c -> JSON in
                ["id": String(c.id), "title": c.title, "unread": c.unread, "muted": c.muted, "last": c.lastText,
                 "time": c.lastDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
            }
            model.log("list chats", only ? "unread only" : "all", "ok")
            return ["ok": true, "chats": Array(list)]
        case "read":
            guard Prefs.shared.agentsCanRead else { return fail("The user has turned off agent access to chats in Hush settings.") }
            switch ChatMatch.resolve(req.str("chat") ?? "", in: s.chats) {
            case .none: return fail("No chat matches that name. Call hush_list_chats first.")
            case .many(let names): return fail("More than one chat matches: \(names.prefix(8).joined(separator: ", ")). Use the chat id.")
            case .one(let c):
                do {
                    let lines = try await s.history(chatId: c.id, limit: Int(max(1, min(req.int("limit") ?? 30, 100))))
                    model.log("read", c.title, "ok")
                    let f = ISO8601DateFormatter()
                    return ["ok": true, "chat": c.title, "messages": lines.map { ["time": f.string(from: $0.date), "sender": $0.sender, "text": $0.text] as JSON }]
                } catch { model.report(error, area: "Reading a chat for an agent"); return fail(error.localizedDescription) }
            }
        case "send":
            guard let text = req.str("text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail("Missing required argument: text") }
            switch ChatMatch.resolve(req.str("chat") ?? "", in: s.chats) {
            case .none: return fail("No chat matches that name. Call hush_list_chats first.")
            case .many(let names): return fail("More than one chat matches: \(names.prefix(8).joined(separator: ", ")). Use the chat id.")
            case .one(let c):
                guard await Approval.ask(chat: c.title, text: text) else {
                    model.log("send", c.title, "denied")
                    return fail("The user denied this request. Do not retry.")
                }
                do { try await s.send(text, to: c.id); model.log("send", c.title, "sent"); return ["ok": true, "sent_to": c.title] }
                catch { model.log("send", c.title, "failed"); model.report(error, area: "Sending for an agent"); return fail(error.localizedDescription) }
            }
        default: return fail("Unknown operation.")
        }
    }
}
