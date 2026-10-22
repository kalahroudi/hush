// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import HushKit

/// The desktop chat window: filter tabs and the chat list on the left, the open conversation on the right.
/// It reuses the popover's rows, thread and compose box. Created when opened and destroyed when closed, like the Settings window.
struct ChatWindowView: View {
    let model = AppModel.shared
    let prefs = Prefs.shared
    var openSettings: () -> Void
    @State private var tab = ChatTab(rawValue: UserDefaults.standard.string(forKey: "windowTab") ?? "") ?? .all
    @State private var query = ""
    @State private var showOlder = false
    @State private var highlighted: Int64?   // the keyboard cursor; not the same as the open chat
    @FocusState private var listFocused: Bool

    var body: some View {
        Group {
            if model.needsSetup { centered { SetupScreen(openSettings: openSettings) } }
            else if model.session.phase != .ready { centered { LoginView() } }
            else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 270)
                    Divider()
                    detail.frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Theme.pane)
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear { model.setPopoverVisible(true) }
        .onDisappear { model.setPopoverVisible(false); if !model.demo { model.session.closeChat() } }
        .onChange(of: tab) { _, t in UserDefaults.standard.set(t.rawValue, forKey: "windowTab") }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().frame(width: 340, height: 480).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sidebar

    /// The displayed order, shared by the list and the keyboard handlers.
    private var result: (shown: [ChatSummary], hidden: Int) {
        ChatListFilter.apply(model.session.chats, tab: tab, query: query, showOlder: showOlder, isFavorite: prefs.isFavorite)
    }

    private var sidebar: some View {
        let chats = model.session.chats
        let result = result
        let unread = ChatListFilter.unreadBadge(chats)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Hush").font(.system(size: 15, weight: .semibold))
                    if !model.session.online { Text("offline").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                    Spacer()
                    Button(action: openSettings) { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Settings").accessibilityLabel("Settings")
                }
                TabBar(tabs: ChatTab.allCases.map { ($0, $0 == .unread && unread > 0 ? "Unread (\(unread))" : $0.label) }, selection: $tab)
                SearchBox(prompt: "Search", text: $query)
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
            Divider()
            if result.shown.isEmpty {
                Spacer()
                Text(emptyText(chats.isEmpty)).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(result.shown) { chat in
                            Button { highlighted = chat.id; select(chat) } label: { InboxView.Row(chat: chat, favorite: prefs.isFavorite(chat.id)) }
                                .buttonStyle(RowStyle())
                                .background(model.session.openChat?.id == chat.id ? Theme.accentSoft : .clear)
                                .overlay { if highlighted == chat.id { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1.5).padding(2) } }
                                .id(chat.id)
                        }
                        if result.hidden > 0 || (showOlder && tab == .all) {
                            Button {
                                showOlder.toggle()
                                if showOlder { model.session.loadMoreChats() }
                            } label: {
                                Text(showOlder ? "Show active only" : "Show \(result.hidden) older").font(.system(size: 11.5)).foregroundStyle(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 10)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(forward: true) }
                .onKeyPress(.upArrow) { move(forward: false) }
                .onKeyPress(.return) { openHighlighted() }
                .onKeyPress(keys: [.tab]) { press in switchChat(forward: !press.modifiers.contains(.shift)); return .handled }
                .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
                .onChange(of: result.shown.map(\.id)) { _, ids in if let h = highlighted, !ids.contains(h) { highlighted = nil } }
                .onAppear { listFocused = true }
                }
            }
        }
        .background(Theme.sidebar)
        .task { openPending() }
        .onChange(of: model.pendingChat) { _, _ in openPending() }
    }

    private func emptyText(_ noChats: Bool) -> String {
        if noChats { return "No chats yet." }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "No chat matches that search." }
        switch tab { case .unread: return "Nothing unread."; case .favorites: return "No favorites yet. Star a chat to add it here."; case .all: return "No chats yet." }
    }

    /// Arrow keys move the highlight only and do not wrap. Starts from the highlight, else the open chat.
    private func move(forward: Bool) -> KeyPress.Result {
        guard let next = ChatNavigation.step(result.shown, from: highlighted ?? model.session.openChat?.id, forward: forward, wrap: false) else { return .ignored }
        highlighted = next.id
        return .handled
    }

    /// Tab and Shift+Tab open the next or previous chat from the open one, wrapping at the ends.
    private func switchChat(forward: Bool) {
        guard let next = ChatNavigation.step(result.shown, from: model.session.openChat?.id, forward: forward, wrap: true) else { return }
        highlighted = next.id
        select(next)
    }

    private func openHighlighted() -> KeyPress.Result {
        guard let id = highlighted, let chat = result.shown.first(where: { $0.id == id }) else { return .ignored }
        select(chat)
        return .handled
    }

    private func select(_ chat: ChatSummary) {
        guard model.session.openChat?.id != chat.id else { return }
        model.session.closeChat()
        model.session.open(chat)
    }

    /// A tapped banner asks for a chat by id.
    private func openPending() {
        guard let id = model.pendingChat, let c = model.session.chats.first(where: { $0.id == id }) else { return }
        model.pendingChat = nil; select(c)
    }

    // MARK: Conversation

    @ViewBuilder private var detail: some View {
        if let chat = model.session.openChat {
            ThreadView(showBack: false, onSwitch: { switchChat(forward: !$0) }).id(chat.id)   // a new view per chat, so the message box takes focus again
        } else {
            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("Select a chat").font(.system(size: 13)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
