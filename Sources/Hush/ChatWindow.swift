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

    private var sidebar: some View {
        let chats = model.session.chats
        let result = ChatListFilter.apply(chats, tab: tab, query: query, showOlder: showOlder, isFavorite: prefs.isFavorite)
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(result.shown) { chat in
                            Button { select(chat) } label: { InboxView.Row(chat: chat, favorite: prefs.isFavorite(chat.id)) }
                                .buttonStyle(RowStyle())
                                .background(model.session.openChat?.id == chat.id ? Theme.accentSoft : .clear)
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
            ThreadView(showBack: false).id(chat.id)   // a new view per chat, so the message box takes focus again
        } else {
            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("Select a chat").font(.system(size: 13)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
