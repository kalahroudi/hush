// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The tabs above the chat list in the desktop window.
public enum ChatTab: String, CaseIterable, Sendable {
    case all, unread, favorites
    public var label: String { rawValue.capitalized }
}

/// Which chats a list shows. Pure, so the popover's "active only" rule and the window's tabs behave the same and are tested.
public enum ChatListFilter {
    /// Chats worth listing without asking: unread, favorite, or active in the last week.
    public static func isActive(_ c: ChatSummary, isFavorite: Bool, now: Date = .now) -> Bool {
        c.unread > 0 || isFavorite || (c.lastDate ?? .distantPast) > now.addingTimeInterval(-7 * 86_400)
    }

    /// `hidden` counts chats the tab would show if older ones were included; it is 0 while searching or when `showOlder` is on.
    public static func apply(_ chats: [ChatSummary], tab: ChatTab, query: String = "", showOlder: Bool = false,
                             isFavorite: (Int64) -> Bool, now: Date = .now) -> (shown: [ChatSummary], hidden: Int) {
        let inTab = chats.filter { c in
            switch tab {
            case .all: true
            case .unread: c.unread > 0
            case .favorites: isFavorite(c.id)
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {   // a search looks through every loaded chat of the tab, old ones included
            return (inTab.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.lastText.localizedCaseInsensitiveContains(q) }, 0)
        }
        // Unread and Favorites are already narrow; only "All" hides quiet chats.
        guard tab == .all, !showOlder else { return (inTab, 0) }
        let shown = inTab.filter { isActive($0, isFavorite: isFavorite($0.id), now: now) }
        return (shown, inTab.count - shown.count)
    }

    /// The number on the Unread tab: chats with unread messages that are not muted.
    public static func unreadBadge(_ chats: [ChatSummary]) -> Int { chats.filter { $0.unread > 0 && !$0.muted }.count }
}
