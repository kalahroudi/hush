// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import HushKit

/// The message box: wraps long text onto new lines and grows up to `maxLines`, then scrolls.
/// Return sends, Shift+Return starts a new line. It takes keyboard focus when it appears and draws an accent border
/// while it has focus, so it is obvious you can type.
struct ComposeField: View {
    @Binding var text: String
    var placeholder = "Message"
    var onSend: () -> Void
    /// Tab (false) and Shift+Tab (true); without it Tab keeps its default behavior.
    var onTab: ((Bool) -> Void)?
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ComposeTextView(text: $text, placeholder: placeholder, focused: $focused, onSend: onSend, onTab: onTab)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? Theme.accent : Theme.hairline, lineWidth: focused ? 1.5 : 1))
            Text(ComposeKey.hint).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 2)
        }
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

private final class KeyTextView: NSTextView {
    var onSend: (() -> Void)?
    var onTab: ((Bool) -> Void)?
    var onFocus: ((Bool) -> Void)?
    var placeholder = ""

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76   // Return, keypad Enter
        if isReturn, !hasMarkedText() {                             // never steal Return from an input method
            let f = event.modifierFlags
            switch ComposeKey.action(shift: f.contains(.shift), option: f.contains(.option), control: f.contains(.control)) {
            case .send: onSend?()
            case .newline: insertNewlineIgnoringFieldEditor(nil)
            }
            return
        }
        if event.keyCode == 48, !hasMarkedText(), let onTab {       // Tab; never steal it from an input method
            onTab(event.modifierFlags.contains(.shift))
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); if r { onFocus?(true) }; return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); if r { onFocus?(false) }; return r }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.makeKey(); w.makeFirstResponder(self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let inset = textContainerInset, pad = textContainer?.lineFragmentPadding ?? 0
        placeholder.draw(at: NSPoint(x: inset.width + pad, y: inset.height),
                         withAttributes: [.font: font ?? .systemFont(ofSize: 13.5), .foregroundColor: NSColor.placeholderTextColor])
    }
}

private struct ComposeTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var focused: Bool
    let onSend: () -> Void
    let onTab: ((Bool) -> Void)?
    static let font = NSFont.systemFont(ofSize: 13.5)
    static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = KeyTextView()
        tv.font = Self.font
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.placeholder = placeholder
        tv.delegate = context.coordinator
        tv.string = text
        tv.setAccessibilityLabel(placeholder)
        let sv = NSScrollView()
        sv.documentView = tv
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        context.coordinator.view = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? KeyTextView else { return }
        if tv.string != text { tv.string = text; tv.needsDisplay = true }
        tv.onSend = onSend
        tv.onTab = onTab
        tv.onFocus = { f in DispatchQueue.main.async { focused = f } }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView sv: NSScrollView, context: Context) -> CGSize? {
        guard let tv = sv.documentView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let width = proposal.width ?? 300
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let line = lm.defaultLineHeight(for: Self.font)
        let h = min(max(lm.usedRect(for: tc).height, line), line * Self.maxLines)
        return CGSize(width: width, height: ceil(h))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeTextView
        weak var view: NSTextView?
        init(_ p: ComposeTextView) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            tv.needsDisplay = true
        }
    }
}
