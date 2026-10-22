// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import HushKit

/// The borderless floating window the favorites stack lives in. It can become key so the stack takes the keyboard.
final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
        .focusable().focusEffectDisabled()
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.downArrow) { move(forward: true) }
        .onKeyPress(.rightArrow) { move(forward: true) }
        .onKeyPress(.upArrow) { move(forward: false) }
        .onKeyPress(.leftArrow) { move(forward: false) }
        .background(ScrollCatcher { forward in _ = move(forward: forward) })
        .onKeyPress("d") {
            guard model.stackMode == .cards, !model.stackReplying else { return .ignored }
            model.markStackDone(); return .handled
        }
        .onKeyPress(.return) {
            guard model.stackMode == .cards, !model.stackReplying else { return .ignored }
            model.stackReplying = true; return .handled
        }
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
        let layers = FavoritesStack.layers(count: model.stackCards.count, selection: model.stackSelection)
        return ZStack {
            ForEach(layers.reversed(), id: \.index) { layer in
                CardView(card: model.stackCards[layer.index], top: layer.depth == 0, model: model)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture { if layer.depth > 0 { select(layer.index) } }   // click a peeking card to bring it up
                CardView(card: model.stackCards[layer.index], top: layer.depth == 0, model: model, close: close)
                    .scaleEffect(1 - CGFloat(layer.depth) * 0.05, anchor: .top)
                    .offset(y: CGFloat(layer.depth) * 14)
                    .opacity(1 - Double(layer.depth) * 0.12)
                    .zIndex(Double(-layer.depth))
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    .transition(!motion.moves ? .opacity : .asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    .allowsHitTesting(layer.depth == 0)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 40).padding(.top, 20)
        .animation(motion == .fade ? .easeInOut(duration: motion.duration) : .spring(duration: motion.duration), value: model.stackSelection)
    }

    private func select(_ index: Int) { model.stackSelection = min(max(index, 0), model.stackCards.count - 1) }

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
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline))
            .shadow(color: .black.opacity((top ? 0.25 : 0.12) * (scheme == .dark ? 2 : 1)), radius: top ? 18 : 8, y: top ? 8 : 3)
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
