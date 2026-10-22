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
    /// The selection after moving one card `forward` or back. It never wraps and always stays inside `0..<count` (0 when empty).
    public static func step(count: Int, selection: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return min(max(selection + (forward ? 1 : -1), 0), count - 1)
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
