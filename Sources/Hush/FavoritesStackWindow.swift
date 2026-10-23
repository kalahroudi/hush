// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import HushKit

/// The borderless floating window the favorites stack lives in. It can become key so the stack takes the keyboard.
final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Gets each key press first; return true when the stack used it. This does not depend on SwiftUI focus, so the arrows work as soon as the stack opens.
    var onKey: ((StackKey) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.modifierFlags.contains(.command), let key = Self.key(for: event), onKey?(key) == true { return }
        super.sendEvent(event)
    }

    private static func key(for event: NSEvent) -> StackKey? {
        switch event.keyCode {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 36, 76: .return
        case 53: .escape
        default: event.charactersIgnoringModifiers.map { .character($0) }
        }
    }
}

/// The focus view: layered cards, or a short message when there is nothing to read. No list, tabs or search.
struct StackView: View {
    let model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    var close: () -> Void

    var body: some View {
        ZStack {
            switch model.stackMode {
            case .cards: cards
            case .caughtUp: message("All caught up", "No fresh messages from your favorites.", symbol: "checkmark.circle")
            case .empty: message("Nothing new", "No unread messages from your favorites.", symbol: "tray")
            }
        }
        .frame(width: 460, height: 360)
        .background(ScrollCatcher { forward in _ = move(forward: forward) })
        .overlay(alignment: .topTrailing) {
            Button(action: close) { Image(systemName: "xmark.circle.fill").font(.system(size: 18)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(8)
                .help("Close").accessibilityLabel("Close")
        }
    }

    private func move(forward: Bool) -> KeyPress.Result {
        guard model.stackMode == .cards else { return .ignored }
        model.stepStack(forward: forward)
        return .handled
    }

    private var cards: some View {
        let motion = StackMotion.resolve(reduceMotion: reduceMotion)
        let layers = FavoritesStack.visibleCards(model.stackCards, selection: model.stackSelection)
        return ZStack {
            ForEach(layers.reversed(), id: \.card.id) { layer in
                CardView(card: layer.card, top: layer.depth == 0, model: model, close: close)
                    .overlay {   // each card further back is a little darker, so the deck reads as layers
                        RoundedRectangle(cornerRadius: 16).fill(.black.opacity(Double(layer.depth) * (scheme == .dark ? 0.12 : 0.05))).allowsHitTesting(false)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture { if layer.depth > 0 { select(layer.card.id) } }   // click a peeking card to bring it up
                    .scaleEffect(x: 1 - CGFloat(layer.depth) * 0.05, y: 1, anchor: .top)
                    .offset(y: CGFloat(layer.depth) * Self.peek)
                    .zIndex(Double(-layer.depth))
                    .transition(!motion.moves ? .opacity : .asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 24 + Self.peek * CGFloat(FavoritesStack.visibleDepth - 1)).padding(.top, 30)
        .overlay(alignment: .top) { positionDots }
        .animation(motion == .fade ? .easeInOut(duration: motion.duration) : .spring(duration: motion.duration), value: model.stackSelection)
    }

    /// How far each card behind shows below the one in front.
    private static let peek: CGFloat = 16

    private var positionDots: some View {
        let count = model.stackCards.count
        return HStack(spacing: 5) {
            ForEach(0..<min(count, 12), id: \.self) { i in
                Circle().fill(i == model.stackSelection ? Theme.accent : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            }
        }
        .padding(.top, 12)
        .accessibilityHidden(true)
    }

    private func select(_ id: Int64) { if let i = model.stackCards.firstIndex(where: { $0.id == id }) { model.stackSelection = i } }

    private func message(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Text("Press Esc to close").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline))
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.25), radius: 18, y: 8)
        .padding(24)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: close)   // a click closes the finished stack, like Esc
        .accessibilityElement(children: .combine)
    }

    struct CardView: View {
        let card: StackCard
        let top: Bool
        let model: AppModel
        var close: () -> Void
        private var draft: Binding<String> {
            let id = card.id
            return Binding(get: { model.draftMessages[id] ?? "" }, set: { model.draftMessages[id] = $0.isEmpty ? nil : $0 })
        }
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(card.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if top {
                        Button("Done", action: model.markStackDone).buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                            .help("Mark read (D)").accessibilityLabel("Mark read")
                    }
                    Text("\(card.unread)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                        .accessibilityLabel("\(card.unread) unread")
                }
                if top {
                    HStack(spacing: 6) {
                        if !card.sender.isEmpty { Text(card.sender).font(.system(size: 12, weight: .medium)) }
                        Text(timeText(card.date)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Text(card.text).font(.system(size: 14)).lineLimit(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                if top { reply }
            }
            .overlay(alignment: .bottom) {   // the strip of a card behind shows who it is from
                if !top {
                    HStack {
                        Text(card.title).lineLimit(1)
                        Spacer()
                        Text("\(card.unread)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).frame(height: 16).padding(.bottom, 1)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline))
            .shadow(color: .black.opacity((top ? 0.25 : 0.12) * (scheme == .dark ? 2 : 1)), radius: top ? 18 : 6, y: top ? 8 : 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FavoritesStack.accessibilityLabel(for: card))
            .modifier(CardActions(enabled: top, model: model, close: close))
        }

        /// The card's actions for the VoiceOver actions rotor; only the top card has any.
        struct CardActions: ViewModifier {
            let enabled: Bool
            let model: AppModel
            var close: () -> Void
            func body(content: Content) -> some View {
                if enabled {
                    content
                        .accessibilityAction(named: "Next card") { model.stepStack(forward: true) }
                        .accessibilityAction(named: "Previous card") { model.stepStack(forward: false) }
                        .accessibilityAction(named: "Reply") { model.stackReplying = true }
                        .accessibilityAction(named: "Mark read") { model.markStackDone() }
                        .accessibilityAction(named: "Close") { close() }
                } else {
                    content
                }
            }
        }

        /// A tap on the placeholder, or Return on the stack, swaps it for the compose field, which takes focus when it appears.
        @ViewBuilder private var reply: some View {
            if model.stackReplying {
                ComposeField(text: draft, placeholder: "Reply", onSend: model.sendStackReply)
            } else {
                Text("Reply…").font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                    .onTapGesture { model.stackReplying = true }
                    .accessibilityAddTraits(.isButton).accessibilityLabel("Reply")
            }
        }
    }
}


/// Reports one step per scroll or swipe gesture over the stack window (positive = next card). It listens with a local event monitor so it never blocks clicks on the cards.
private struct ScrollCatcher: NSViewRepresentable {
    var onStep: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Catcher() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Catcher)?.onStep = onStep }

    final class Catcher: NSView {
        var onStep: (Bool) -> Void = { _ in }
        private var monitor: Any?
        private var scroll = StackScroll()

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.phase == .began || event.phase == .mayBegin { self.scroll.end() }
                let (dx, dy) = (event.scrollingDeltaX, event.scrollingDeltaY)
                if let forward = self.scroll.add(Double(abs(dy) >= abs(dx) ? -dy : -dx)) { self.onStep(forward) }
                if event.phase == .ended || event.momentumPhase == .ended || event.phase == .cancelled { self.scroll.end() }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
