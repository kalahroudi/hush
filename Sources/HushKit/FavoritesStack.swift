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

/// Turns a stream of scroll or swipe deltas into one card step per gesture, so trackpad inertia cannot skip through the stack.
public struct StackScroll: Equatable, Sendable {
    public static let threshold: Double = 12
    private var total: Double = 0
    private var fired = false
    public init() {}

    /// Adds a delta (positive = next card). Returns `true` for next, `false` for previous, nil until the threshold is crossed, and nil again until `end()`.
    public mutating func add(_ delta: Double) -> Bool? {
        guard !fired else { return nil }
        total += delta
        guard abs(total) >= Self.threshold else { return nil }
        fired = true
        return total > 0
    }

    /// The gesture and its momentum finished: the next delta starts a new gesture.
    public mutating func end() { self = StackScroll() }
}

extension FavoritesStack {
    /// The chat a reply typed on the top card goes to: the selected card's chat, or nil when there is no such card.
    public static func replyTarget(cards: [StackCard], selection: Int) -> Int64? {
        cards.indices.contains(selection) ? cards[selection].id : nil
    }
}

extension FavoritesStack {
    /// The stack after a card was handled: the remaining cards, where the selection sits, and what to show.
    public struct Removal: Equatable, Sendable {
        public var cards: [StackCard]
        public var selection: Int
        public var mode: StackMode
    }

    /// Drops the card for `id`. The next card comes forward, or the previous one when the last card went. Removing the final card gives `.caughtUp`; an unknown id changes nothing.
    public static func dropCard(id: Int64, from cards: [StackCard], selection: Int) -> Removal {
        guard let at = cards.firstIndex(where: { $0.id == id }) else {
            return Removal(cards: cards, selection: selection, mode: cards.isEmpty ? .caughtUp : .cards)
        }
        var rest = cards; rest.remove(at: at)
        guard !rest.isEmpty else { return Removal(cards: rest, selection: 0, mode: .caughtUp) }
        var next = selection
        if at < selection { next -= 1 }
        return Removal(cards: rest, selection: min(max(next, 0), rest.count - 1), mode: .cards)
    }
}

extension FavoritesStack {
    /// What VoiceOver reads for a card: the chat title, the unread count, then the newest message text.
    public static func accessibilityLabel(for card: StackCard) -> String {
        let count = card.unread == 1 ? "1 unread message" : "\(card.unread) unread messages"
        return [card.title, count, card.text].filter { !$0.isEmpty }.joined(separator: ", ")
    }

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

/// How the stack changes cards: a slide with a spring normally, a short plain fade when Reduce Motion is on (R12).
public enum StackMotion: Equatable, Sendable {
    case slide, fade

    public static func resolve(reduceMotion: Bool) -> StackMotion { reduceMotion ? .fade : .slide }

    /// Seconds a card change takes. A fade is short and has no spring.
    public var duration: Double { self == .fade ? 0.15 : 0.3 }
    /// Whether outgoing cards travel across the window. A fade keeps every card in place.
    public var moves: Bool { self == .slide }
}

extension FavoritesStack {
    /// The cards to draw with their depth (0 = top), taken from `cards` itself so a view never indexes a list that has since shrunk.
    public static func visibleCards(_ cards: [StackCard], selection: Int) -> [(card: StackCard, depth: Int)] {
        layers(count: cards.count, selection: selection).map { (cards[$0.index], $0.depth) }
    }
}

/// A key pressed over the stack window.
public enum StackKey: Equatable, Sendable {
    case up, down, left, right, `return`, escape, character(String)
}

/// What a key does in the stack.
public enum StackKeyAction: Equatable, Sendable {
    case next, previous, reply, done, close
    /// Leave the reply field, keeping the draft, so the arrow keys move between cards again.
    case cancelReply
}

extension StackKey {
    /// The action for a key, or nil to let it through (to the reply field while replying).
    /// While replying only Esc is ours: it leaves the field first, and only the next Esc closes the stack.
    /// The exception is an empty reply field: there is nothing to lose and no caret to move, so the arrows still change card.
    public func action(replying: Bool, mode: StackMode, draftIsEmpty: Bool = false) -> StackKeyAction? {
        if self == .escape { return replying ? .cancelReply : .close }
        guard mode == .cards else { return nil }
        if replying {
            guard draftIsEmpty else { return nil }
            switch self {
            case .down, .right: return .next
            case .up, .left: return .previous
            default: return nil
            }
        }
        switch self {
        case .down, .right: return .next
        case .up, .left: return .previous
        case .return: return .reply
        case .character(let c): return c.lowercased() == "d" ? .done : nil
        case .escape: return nil
        }
    }
}
