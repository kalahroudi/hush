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
        let layers = FavoritesStack.layers(count: model.stackCards.count, selection: model.stackSelection)
        return ZStack {
            ForEach(layers.reversed(), id: \.index) { layer in
                CardView(card: model.stackCards[layer.index], top: layer.depth == 0)
                    .scaleEffect(1 - CGFloat(layer.depth) * 0.05, anchor: .top)
                    .offset(y: CGFloat(layer.depth) * 14)
                    .opacity(1 - Double(layer.depth) * 0.12)
                    .zIndex(Double(-layer.depth))
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    .allowsHitTesting(layer.depth == 0)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 40).padding(.top, 20)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3), value: model.stackSelection)
    }

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
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .padding(24)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: close)   // a click closes the finished stack, like Esc
        .accessibilityElement(children: .combine)
    }

    struct CardView: View {
        let card: StackCard
        let top: Bool
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(card.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer()
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
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline))
            .shadow(color: .black.opacity(top ? 0.25 : 0.12), radius: top ? 18 : 8, y: top ? 8 : 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(card.title), \(card.unread) unread. \(card.text)")
        }
    }
}
