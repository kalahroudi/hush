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

    /// Favorites are listed first in every tab and search, then the rest, each in the order given. `hidden` counts chats the tab would show if older ones were included; it is 0 while searching or when `showOlder` is on.
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
            return (favoritesFirst(inTab.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.lastText.localizedCaseInsensitiveContains(q) }, isFavorite), 0)
        }
        // Unread and Favorites are already narrow; only "All" hides quiet chats.
        guard tab == .all, !showOlder else { return (favoritesFirst(inTab, isFavorite), 0) }
        let shown = inTab.filter { isActive($0, isFavorite: isFavorite($0.id), now: now) }
        return (favoritesFirst(shown, isFavorite), inTab.count - shown.count)
    }

    /// Stable partition: favorites above everyone else, each group keeping its input order (not `sort`, which is not stable).
    private static func favoritesFirst(_ chats: [ChatSummary], _ isFavorite: (Int64) -> Bool) -> [ChatSummary] {
        chats.filter { isFavorite($0.id) } + chats.filter { !isFavorite($0.id) }
    }

    /// The number on the Unread tab: chats with unread messages that are not muted.
    public static func unreadBadge(_ chats: [ChatSummary]) -> Int { chats.filter { $0.unread > 0 && !$0.muted }.count }
}

/// Which chat a navigation key lands on. Pure, and given the list `ChatListFilter.apply` returns, so it follows the displayed order.
public enum ChatNavigation {
    /// The chat after (`forward`) or before `from` in `chats`. At the ends it wraps to the other end, or stays put when `wrap` is off. A nil or unknown `from` gives the first chat going forward and the last going backward. Nil only for an empty list.
    public static func step(_ chats: [ChatSummary], from: Int64?, forward: Bool, wrap: Bool) -> ChatSummary? {
        guard let first = chats.first, let last = chats.last else { return nil }
        guard let from, let i = chats.firstIndex(where: { $0.id == from }) else { return forward ? first : last }
        let j = forward ? i + 1 : i - 1
        if chats.indices.contains(j) { return chats[j] }
        return wrap ? (forward ? first : last) : chats[i]
    }
}
