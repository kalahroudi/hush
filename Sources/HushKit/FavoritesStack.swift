import Foundation

/// One card of the favorites stack: a favorite chat with unread messages.
public struct StackCard: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var unread: Int
    /// The unread messages, oldest first.
    public var lines: [Line]
    /// What the top of the card shows: sender, text and time of the newest message.
    public var sender: String
    public var text: String
    public var date: Date?
    public init(id: Int64, title: String, unread: Int, lines: [Line], sender: String, text: String, date: Date?) {
        self.id = id; self.title = title; self.unread = unread; self.lines = lines; self.sender = sender; self.text = text; self.date = date
    }
}

/// What the stack window shows: cards, or one of two short messages.
public enum StackMode: Equatable, Sendable {
    case cards
    /// Every card was handled.
    case caughtUp
    /// There was nothing fresh when the stack was invoked.
    case empty

    /// The mode a freshly built stack opens in: an empty stack never shows cards.
    public static func opening(with cards: [StackCard]) -> StackMode { cards.isEmpty ? .empty : .cards }
}

/// Which cards the favorites stack shows and in what order. Pure, like `ChatListFilter`, so it is tested without a session.
public enum FavoritesStack {
    /// One card per favorite chat with unread messages, most recent activity first. Ties follow Telegram's `order` (higher first), then id, so the result is deterministic.
    /// `lines` returns the unread messages for a chat in any order; a card keeps them oldest first. When a chat has none loaded, the card falls back to the chat's last message text.
    public static func build(chats: [ChatSummary], isFavorite: (Int64) -> Bool, lines: (Int64) -> [Line]) -> [StackCard] {
        let cards: [(card: StackCard, chat: ChatSummary)] = chats
            .filter { $0.unread > 0 && isFavorite($0.id) }
            .map { chat in
                let sorted = lines(chat.id).enumerated()
                    .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
                    .map(\.element)
                let newest = sorted.last
                let card = StackCard(id: chat.id, title: chat.title, unread: chat.unread, lines: sorted,
                                     sender: newest?.sender ?? "", text: newest?.text ?? chat.lastText,
                                     date: newest?.date ?? chat.lastDate)
                return (card, chat)
            }
        return cards.sorted { a, b in
            let (x, y) = (a.chat.lastDate ?? .distantPast, b.chat.lastDate ?? .distantPast)
            if x != y { return x > y }
            if a.chat.order != b.chat.order { return a.chat.order > b.chat.order }
            return a.chat.id < b.chat.id
        }.map(\.card)
    }

    /// The card after (`forward`) or before `from`. The stack never wraps: at either end the selection stays put. A nil or unknown `from` gives the first card going forward and the last going backward. Nil only for an empty stack.
    public static func step(_ cards: [StackCard], from: Int64?, forward: Bool) -> Int64? {
        guard let first = cards.first, let last = cards.last else { return nil }
        guard let from, let i = cards.firstIndex(where: { $0.id == from }) else { return (forward ? first : last).id }
        let j = forward ? i + 1 : i - 1
        return cards.indices.contains(j) ? cards[j].id : cards[i].id
    }

    /// What the stack shows: its cards, the "all caught up" state after the last card was dealt with, or the empty state when it was opened with nothing fresh.
    public enum Mode: Equatable, Sendable { case cards, caughtUp, empty }

    /// The mode for a freshly built stack: `.empty` with no cards, so no empty stack is ever shown.
    public static func mode(for cards: [StackCard]) -> Mode { cards.isEmpty ? .empty : .cards }

    /// Drops the card for `id` after a reply or mark-read. The selection moves to the next card, or to the previous one when the last card was removed. Removing the final card gives `.caughtUp`. An unknown id changes nothing.
    public static func remove(id: Int64, from cards: [StackCard], selection: Int64?) -> (cards: [StackCard], selection: Int64?, mode: Mode) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else {
            return (cards, selection, cards.isEmpty ? .empty : .cards)
        }
        var rest = cards
        rest.remove(at: i)
        if rest.isEmpty { return (rest, nil, .caughtUp) }
        // Removing a card that is not selected leaves the selection where it was.
        if let selection, selection != id, rest.contains(where: { $0.id == selection }) { return (rest, selection, .cards) }
        return (rest, rest[min(i, rest.count - 1)].id, .cards)
    }

    /// The stack after applying a fresh snapshot of the chats while it is open.
    public struct Merged: Equatable, Sendable {
        public var cards: [StackCard]
        /// New chats held back until the reply ends.
        public var queued: [StackCard]
        /// The selected index after the merge; it keeps pointing at the same card.
        public var selection: Int
    }

    /// Applies incoming changes (R14). A card already in the stack (or the queue) is updated in place: count, text and lines change, its position does not.
    /// A favorite chat with unread messages that is new goes on top, newest first, unless `isReplying`; then it waits in `queued` and is added by the next merge made with `isReplying: false`.
    /// Chats that are not unread favorites are ignored here; removing cards is `remove`'s job. The selection follows the card it was on, so the card being replied to never changes under the user.
    public static func merge(cards: [StackCard], queued: [StackCard] = [], selection: Int, chats: [ChatSummary], isFavorite: (Int64) -> Bool, lines: (Int64) -> [Line], isReplying: Bool) -> Merged {
        var cards = cards, queued = queued
        let selectedId = cards.indices.contains(selection) ? cards[selection].id : nil
        var fresh: [ChatSummary] = []
        for chat in chats where chat.unread > 0 && isFavorite(chat.id) {
            if let i = cards.firstIndex(where: { $0.id == chat.id }), let card = build(chats: [chat], isFavorite: { _ in true }, lines: lines).first {
                cards[i] = card
            } else if let i = queued.firstIndex(where: { $0.id == chat.id }), let card = build(chats: [chat], isFavorite: { _ in true }, lines: lines).first {
                queued[i] = card
            } else {
                fresh.append(chat)
            }
        }
        var incoming = build(chats: fresh, isFavorite: { _ in true }, lines: lines)
        if isReplying {
            queued += incoming
            return Merged(cards: cards, queued: queued, selection: selection)
        }
        incoming = (queued + incoming).enumerated()
            .sorted { ($0.element.date ?? .distantPast, $1.offset) > ($1.element.date ?? .distantPast, $0.offset) }
            .map(\.element)
        cards = incoming + cards
        let kept = selectedId.flatMap { id in cards.firstIndex { $0.id == id } } ?? selection
        return Merged(cards: cards, queued: [], selection: cards.isEmpty ? 0 : min(kept, cards.count - 1))
    }
}

extension FavoritesStack {
    /// How many cards show at once: the top one and the edges of the next few behind it.
    public static let visibleDepth = 4

    /// The selection after moving one card forward or back. It never wraps and always stays in bounds (0 for an empty stack).
    public static func step(count: Int, selection: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        let current = min(max(selection, 0), count - 1)
        return min(max(current + (forward ? 1 : -1), 0), count - 1)
    }

    /// Which cards are drawn and how deep each sits (0 = top). Cards before the selection are gone, cards beyond `visibleDepth` are not drawn.
    public static func layers(count: Int, selection: Int) -> [(index: Int, depth: Int)] {
        guard count > 0 else { return [] }
        let top = min(max(selection, 0), count - 1)
        return (top..<min(count, top + visibleDepth)).map { ($0, $0 - top) }
    }
}
