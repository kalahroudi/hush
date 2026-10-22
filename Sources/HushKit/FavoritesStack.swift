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
}

extension FavoritesStack {
    /// How many cards show at once: the top one and the edges of the next few behind it.
    public static let visibleDepth = 4

    /// Which cards are drawn and how deep each sits (0 = top). Cards before the selection are gone, cards beyond `visibleDepth` are not drawn.
    public static func layers(count: Int, selection: Int) -> [(index: Int, depth: Int)] {
        guard count > 0 else { return [] }
        let top = min(max(selection, 0), count - 1)
        return (top..<min(count, top + visibleDepth)).map { ($0, $0 - top) }
    }
}

extension FavoritesStack {
    /// The chat a reply typed on the top card goes to: the selected card's chat, or nil when there is no such card.
    public static func replyTarget(cards: [StackCard], selection: Int) -> Int64? {
        cards.indices.contains(selection) ? cards[selection].id : nil
    }
}

extension FavoritesStack {
    /// Applies one incoming message while the stack is open. A chat already in the stack (or waiting in `queued`) gets its count and newest text updated in place, so the order and the selection do not move.
    /// A new favorite chat goes on top with the selection on it, unless the user is replying: then it waits in `queued` so the card being replied to does not change.
    /// `chat` is the chat as the session knows it; its unread count may not include this message yet, so a known card counts one more.
    public static func merge(cards: [StackCard], queued: [StackCard], selection: Int, chat: ChatSummary, line: Line, isReplying: Bool)
        -> (cards: [StackCard], queued: [StackCard], selection: Int) {
        func apply(_ card: inout StackCard) {
            guard !card.lines.contains(where: { $0.id == line.id }) else { return }
            card.unread += 1
            card.lines.append(line)
            card.sender = line.sender; card.text = line.text; card.date = line.date
        }
        var cards = cards, queued = queued
        if let i = cards.firstIndex(where: { $0.id == chat.id }) { apply(&cards[i]); return (cards, queued, selection) }
        if let i = queued.firstIndex(where: { $0.id == chat.id }) { apply(&queued[i]); return (cards, queued, selection) }
        let card = StackCard(id: chat.id, title: chat.title, unread: max(chat.unread, 1), lines: [line],
                             sender: line.sender, text: line.text, date: line.date)
        if isReplying { queued.append(card); return (cards, queued, selection) }
        return ([card] + cards, queued, 0)
    }

    /// Brings the queued chats onto the stack once the reply ends. The newest queued chat ends up on top and the selection moves to it.
    public static func flush(cards: [StackCard], queued: [StackCard], selection: Int) -> (cards: [StackCard], queued: [StackCard], selection: Int) {
        guard !queued.isEmpty else { return (cards, queued, selection) }
        return (queued.reversed() + cards, [], 0)
    }
}
