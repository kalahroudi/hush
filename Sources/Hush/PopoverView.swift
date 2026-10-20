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

private func timeText(_ d: Date?) -> String {
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

    /// Chats worth listing: unread, favorite, or active in the last week. The rest hide behind "show all".
    private var visible: [ChatSummary] {
        let all = model.session.chats
        if showAll { return all }
        let cutoff = Date.now.addingTimeInterval(-7 * 86_400)
        return all.filter { $0.unread > 0 || prefs.isFavorite($0.id) || ($0.lastDate ?? .distantPast) > cutoff }
    }

    var body: some View {
        let shown = visible
        let hidden = model.session.chats.count - shown.count
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { chat in
                            Button { model.session.open(chat) } label: { Row(chat: chat, favorite: prefs.isFavorite(chat.id)) }.buttonStyle(RowStyle())
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
            }
            HStack {
                Text(hidden > 0 ? "\(shown.count) of \(model.session.chats.count) chats" : "\(shown.count) chats").font(.system(size: 10.5, design: .monospaced))
                Spacer()
                Text(model.demo ? "" : AppMemory.footprint).font(.system(size: 10.5, design: .monospaced))
            }.foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6).overlay(alignment: .top) { Divider() }
        }
        .task {
            if let id = model.pendingChat, let c = model.session.chats.first(where: { $0.id == id }) { model.pendingChat = nil; model.session.open(c) }
        }
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.accentSoft : .clear)
    }
}

struct ThreadView: View {
    let model = AppModel.shared
    let prefs = Prefs.shared
    @State private var sending = false
    private var draft: Binding<String> {
        let id = model.session.openChat?.id ?? 0
        return Binding(get: { model.draftMessages[id] ?? "" }, set: { model.draftMessages[id] = $0.isEmpty ? nil : $0 })
    }
    @FocusState private var focused: Bool

    var body: some View {
        let s = model.session
        let chat = s.openChat
        VStack(spacing: 0) {
            Header {
                Button { s.closeChat() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Back").accessibilityLabel("Back")
                Text(chat?.title ?? "").font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            } trailing: {
                if let id = chat?.id {
                    let fav = prefs.isFavorite(id)
                    Button { prefs.toggleFavorite(id) } label: { Image(systemName: fav ? "star.fill" : "star") }
                        .buttonStyle(.plain).foregroundStyle(fav ? Theme.accent : .secondary)
                        .help(fav ? "Favorite: banners are on" : "Make favorite to get banners").accessibilityLabel("Favorite")
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(s.lines) { l in
                            (Text(l.date.formatted(date: .omitted, time: .shortened) + "  ").font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary)
                             + Text(l.sender + " ").font(.system(size: 13.5, weight: .semibold)).foregroundColor(l.outgoing ? Theme.accent : .primary)
                             + Text(l.text).font(.system(size: 13.5)).foregroundColor(l.text.hasPrefix("[") && l.text.hasSuffix("]") ? .secondary : .primary))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(l.id)
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 10)
                }
                .onChange(of: s.lines.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
                .onAppear { if let id = s.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            HStack(spacing: 8) {
                TextField("Message", text: draft).textFieldStyle(.plain).font(.system(size: 13.5)).focused($focused).onSubmit(send).disabled(sending)
                Text("Return").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 11).overlay(alignment: .top) { Divider() }
        }
        .onAppear { focused = true; NSApp.keyWindow?.makeFirstResponder(nil); focused = true }
    }

    private func send() {
        guard let id = model.session.openChat?.id, !draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let text = draft.wrappedValue; model.draftMessages[id] = nil; sending = true
        Task {
            do { try await model.session.send(text, to: id) } catch { model.draftMessages[id] = text; model.show(error.localizedDescription, error: true) }
            sending = false; focused = true
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
