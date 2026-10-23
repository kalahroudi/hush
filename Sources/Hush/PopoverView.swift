// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import HushKit

/// The whole product: a list of chats, one conversation, one box to type in. Fixed size; views are dropped when it closes.
struct PopoverView: View {
    let model = AppModel.shared
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.needsSetup { SetupScreen(openSettings: openSettings) }
                else if model.session.phase != .ready { LoginView() }
                else if model.session.openChat != nil { ThreadView() }
                else { InboxView(openSettings: openSettings) }
            }
        }
        .frame(width: 340, height: 480)
        .background(Theme.pane)                                   // opaque and themed: the popover must follow the app theme
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear { model.setPopoverVisible(true) }
        .onDisappear { model.setPopoverVisible(false); if !model.demo { model.session.closeChat() } }
    }
}

func timeText(_ d: Date?) -> String {
    guard let d else { return "" }
    if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if Calendar.current.isDate(d, equalTo: .now, toGranularity: .weekOfYear) { return d.formatted(.dateTime.weekday(.abbreviated)) }
    return d.formatted(.dateTime.day().month(.abbreviated))
}

struct Header<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) { leading; Spacer(minLength: 6); trailing }
            .padding(.horizontal, 14).frame(height: 44)
            .overlay(alignment: .bottom) { Divider() }
    }
}

struct InboxView: View {
    let model = AppModel.shared
    let prefs = Prefs.shared
    var openSettings: () -> Void
    @State private var showAll = false
    /// The keyboard highlight: arrows move it, Enter opens it. The inbox never has an open chat, so this is its only selection.
    @State private var highlighted: Int64?
    @FocusState private var listFocused: Bool

    var body: some View {
        // Same ordering and "older" rule as the desktop window: favorites first, quiet chats behind "show all".
        let (shown, hidden) = ChatListFilter.apply(model.session.chats, tab: .all, showOlder: showAll, isFavorite: prefs.isFavorite)
        VStack(spacing: 0) {
            Header {
                Text("Hush").font(.system(size: 13.5, weight: .semibold))
                if !model.session.online { Text("offline").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
            } trailing: {
                Button(action: openSettings) { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Settings").accessibilityLabel("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Quit Hush").accessibilityLabel("Quit")
            }
            if model.session.chats.isEmpty {
                Spacer(); Text("No chats yet.").font(.system(size: 12.5)).foregroundStyle(.secondary); Spacer()
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { chat in
                            Button { model.session.open(chat) } label: { Row(chat: chat, favorite: prefs.isFavorite(chat.id)) }
                                .buttonStyle(RowStyle(highlighted: chat.id == highlighted)).id(chat.id)
                        }
                        if hidden > 0 || showAll {
                            Button {
                                showAll.toggle()
                                if showAll { model.session.loadMoreChats() }
                            } label: {
                                Text(showAll ? "Show active only" : "Show \(hidden) older")
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 10)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .focusable().focusEffectDisabled().focused($listFocused)
                .onKeyPress(phases: .down) { keyPress($0, shown) }
                .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
                .onChange(of: shown.map(\.id)) { _, ids in if let h = highlighted, !ids.contains(h) { highlighted = nil } }
                }
            }
            HStack {
                Text(hidden > 0 ? "\(shown.count) of \(model.session.chats.count) chats" : "\(shown.count) chats").font(.system(size: 10.5, design: .monospaced))
                Spacer()
                Text(model.demo ? "" : AppMemory.footprint).font(.system(size: 10.5, design: .monospaced))
            }.foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6).overlay(alignment: .top) { Divider() }
        }
        .onAppear { listFocused = true }
        .task {
            if let id = model.pendingChat, let c = model.session.chats.first(where: { $0.id == id }) { model.pendingChat = nil; model.session.open(c) }
        }
    }

    /// Arrows move the highlight without wrapping, Enter opens it, Tab opens the first chat (none is open here), Shift+Tab the last. Ignored while an input method is composing.
    private func keyPress(_ press: KeyPress, _ shown: [ChatSummary]) -> KeyPress.Result {
        if (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return .ignored }
        switch press.key {
        case .downArrow, .upArrow:
            guard let c = ChatNavigation.step(shown, from: highlighted, forward: press.key == .downArrow, wrap: false) else { return .ignored }
            highlighted = c.id
        case .return:
            guard let h = highlighted, let c = shown.first(where: { $0.id == h }) else { return .ignored }
            model.session.open(c)
        case .tab:
            guard let c = ChatNavigation.step(shown, from: nil, forward: !press.modifiers.contains(.shift), wrap: true) else { return .ignored }
            model.session.open(c)
        default: return .ignored
        }
        return .handled
    }

    struct Row: View {
        let chat: ChatSummary
        let favorite: Bool
        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(chat.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.accent) }
                    Spacer(minLength: 6)
                    Text(timeText(chat.lastDate)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(chat.lastText).font(.system(size: 12.5)).foregroundStyle(chat.unread > 0 && !chat.muted ? Color.primary : .secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    if chat.unread > 0 { Text("\(chat.unread)").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(chat.muted ? .secondary : Theme.accent) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }
            .contentShape(Rectangle())
        }
    }
}

struct RowStyle: ButtonStyle {
    var highlighted = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.accentSoft : .clear)
            .overlay { if highlighted { Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5) } }
    }
}

struct ThreadView: View {
    let model = AppModel.shared
    let prefs = Prefs.shared
    /// The popover needs a way back to the inbox; the desktop window keeps its chat list on screen instead.
    var showBack = true
    /// Tab (false) and Shift+Tab (true) in the message box switch chats; nil leaves Tab alone.
    var onSwitch: ((Bool) -> Void)?
    @State private var sending = false
    /// True while the end of the history is on screen; drives the jump-to-latest button.
    @State private var atBottom = true
    @State private var scroller = ThreadScroller()
    private var draft: Binding<String> {
        let id = model.session.openChat?.id ?? 0
        return Binding(get: { model.draftMessages[id] ?? "" }, set: { model.draftMessages[id] = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        let s = model.session
        let chat = s.openChat
        VStack(spacing: 0) {
            Header {
                if showBack { Button { s.closeChat() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Back").accessibilityLabel("Back") }
                Text(chat?.title ?? "").font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            } trailing: {
                if let id = chat?.id {
                    let fav = prefs.isFavorite(id)
                    Button { prefs.toggleFavorite(id) } label: { Image(systemName: fav ? "star.fill" : "star") }
                        .buttonStyle(.plain).foregroundStyle(fav ? Theme.accent : .secondary)
                        .help(fav ? "Favorite: banners and the menu bar count are on" : "Make favorite to get banners and a menu bar count").accessibilityLabel("Favorite")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(s.lines) { l in
                        (Text(l.date.formatted(date: .omitted, time: .shortened) + "  ").font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary)
                         + Text(l.sender + " ").font(.system(size: 13.5, weight: .semibold)).foregroundColor(l.outgoing ? Theme.accent : .primary)
                         + Text(l.text).font(.system(size: 13.5)).foregroundColor(l.text.hasPrefix("[") && l.text.hasSuffix("]") ? .secondary : .primary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Selection is enabled once on the container, not on every row: per-row selectable text can swallow wheel events.
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                // Sits inside the scroll view so it can find the AppKit scroll view that backs it.
                .background(ScrollBridge(scroller: scroller, onAtBottom: { atBottom = $0 }))
            }
            // A different chat opens at its newest message, whatever the previous one was scrolled to.
            .onChange(of: chat?.id) { _, _ in scroller.follow() }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom, !s.lines.isEmpty {
                    Button { scroller.follow() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                            .background(.regularMaterial, in: Circle()).overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                    }
                    .buttonStyle(.plain).padding(12).help("Jump to the latest message").accessibilityLabel("Jump to the latest message")
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: atBottom)
            ComposeField(text: draft, onSend: send, onTab: onSwitch)
                .padding(.horizontal, 14).padding(.vertical, 10).overlay(alignment: .top) { Divider() }
        }
    }

    private func send() {
        guard !sending, let id = model.session.openChat?.id, !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft.wrappedValue; model.draftMessages[id] = nil; sending = true; scroller.follow()
        Task {
            do { try await model.session.send(text, to: id) } catch { model.draftMessages[id] = text; model.report(error, area: "Sending a message") }
            sending = false
        }
    }
}

/// Telegram sign-in: phone, then code, then password if the account has one.
struct LoginView: View {
    let model = AppModel.shared
    var body: some View {
        @Bindable var m = model
        let s = model.session
        VStack(alignment: .leading, spacing: 12) {
            switch s.phase {
            case .waitPhone:
                title("Sign in to Telegram", "Use the phone number of your Telegram account. Your session stays on this Mac.")
                TextField("+44 7700 900123", text: $m.draftPhone).textFieldStyle(.roundedBorder).onSubmit { s.submitPhone(m.draftPhone) }
                Button("Send code") { s.submitPhone(m.draftPhone) }.buttonStyle(Pill(kind: .primary)).disabled(m.draftPhone.isEmpty)
            case .waitCode(let hint):
                title("Enter the code", hint)
                TextField("12345", text: $m.draftCode).textFieldStyle(.roundedBorder).font(.system(size: 14, design: .monospaced)).onSubmit { s.submitCode(m.draftCode) }
                Button("Continue") { s.submitCode(m.draftCode) }.buttonStyle(Pill(kind: .primary)).disabled(m.draftCode.isEmpty)
            case .waitPassword(let hint):
                title("Two-step password", hint.isEmpty ? "Your account has a cloud password." : "Hint: \(hint)")
                SecureField("Password", text: $m.draftPassword).textFieldStyle(.roundedBorder).onSubmit { s.submitPassword(m.draftPassword) }
                Button("Continue") { s.submitPassword(m.draftPassword) }.buttonStyle(Pill(kind: .primary)).disabled(m.draftPassword.isEmpty)
            case .unsupported(let m):
                title("Can't sign in", m)
            default:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting to Telegram…").font(.system(size: 12.5)).foregroundStyle(.secondary) }
            }
            if let e = s.error { Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            Spacer()
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 40)
    }

    private func title(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.system(size: 16, weight: .semibold))
            Text(d).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown instead of an empty popover until TDLib and the Telegram API key are in place.
struct SetupScreen: View {
    var openSettings: () -> Void
    var body: some View {
        ScrollView { SetupView(compact: true).padding(18) }
    }
}

/// Drives the AppKit scroll view behind a SwiftUI ScrollView: while `stick` is set it keeps the end in view as the content grows
/// (history loading in, rows laying out, new messages), and it reports whether the reader is at the end.
@MainActor final class ThreadScroller: NSObject {
    private weak var scrollView: NSScrollView?
    private var stick = true
    var onAtBottom: ((Bool) -> Void)?

    func attach(_ view: NSView) {
        guard scrollView == nil, let sv = view.enclosingScrollView, let doc = sv.documentView else { return }
        scrollView = sv
        sv.contentView.postsBoundsChangedNotifications = true
        doc.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: sv.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(contentChanged), name: NSView.frameDidChangeNotification, object: doc)
        scrollToEnd()
    }

    /// Scrolls to the newest message and keeps following until the reader scrolls away.
    func follow() { stick = true; scrollToEnd(); DispatchQueue.main.async { [weak self] in self?.scrollToEnd() } }

    private var distanceFromEnd: CGFloat {
        guard let sv = scrollView, let doc = sv.documentView else { return 0 }
        return doc.frame.height - sv.contentView.bounds.maxY
    }

    private func scrollToEnd() {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let y = max(0, doc.frame.height - sv.contentView.bounds.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
        onAtBottom?(true)
    }

    @objc private func boundsChanged() {
        let near = distanceFromEnd < 24
        stick = near
        onAtBottom?(near)
    }

    @objc private func contentChanged() {
        if stick { scrollToEnd() } else { onAtBottom?(distanceFromEnd < 24) }
    }
}

private struct ScrollBridge: NSViewRepresentable {
    let scroller: ThreadScroller
    let onAtBottom: (Bool) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        scroller.onAtBottom = onAtBottom
        DispatchQueue.main.async { scroller.attach(view) }
    }
}
