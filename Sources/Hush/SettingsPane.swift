// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import HushKit
@preconcurrency import UserNotifications

/// RULES: every tab has content (no empty pages); every control writes straight to Prefs and takes effect at once
/// ("Settings save automatically", no Apply button); every option has a one-line explanation.
/// To add a setting: add one `item(...)` in `items`. It lands in its tab and is found by search automatically.
struct SettingsPane: View {
    let prefs = Prefs.shared
    @State private var tab: Tab
    @State private var query = ""
    @FocusState private var searching: Bool
    enum Tab: Hashable { case general, notifications, shortcuts, updates, agents, about }
    init(initialTab: Tab = .general) { _tab = State(initialValue: initialTab) }

    /// One searchable setting: where it lives, what it says, and the row to draw.
    private struct Item: Identifiable {
        let tab: Tab
        let group: String
        let title: String
        let detail: String
        let keywords: String
        let row: AnyView
        var id: String { "\(tab)/\(group)/\(title)" }
        func matches(_ q: String) -> Bool {
            q.lowercased().split(separator: " ").allSatisfy { w in [title, detail, keywords, group].contains { $0.lowercased().contains(w) } }
        }
    }

    private static let names: [(Tab, String)] = [(.general, "General"), (.notifications, "Notifications"), (.shortcuts, "Shortcuts"), (.updates, "Updates"), (.agents, "Agents (MCP)"), (.about, "About")]
    private var searchTerm: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Settings") {
                searchField
            } tabs: {
                TabBar(tabs: Self.names, selection: $tab)
            }
            ScrollView {
                Group {
                    if !searchTerm.isEmpty { results }
                    else {
                        switch tab {
                        case .general, .notifications, .shortcuts: page(tab)
                        case .updates: UpdatesView()
                        case .agents: AgentsView()
                        case .about: about
                        }
                    }
                }.padding(22).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Text("Hush \(BuildInfo.current.version) · github.com/kalahroudi/hush"); Spacer(); Text("Settings save automatically") }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 8)
        }
        .onAppear { AppModel.shared.refreshNotificationAccess() }   // the user may have changed it in System Settings
        .background { Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).opacity(0).allowsHitTesting(false) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search settings", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
                .onExitCommand { query = ""; searching = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5).frame(width: 220)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }

    // MARK: pages and search results

    /// A tab's items, in order, grouped under their titles.
    private func page(_ t: Tab) -> some View {
        let groups = groupsIn(items.filter { $0.tab == t })
        return VStack(spacing: 18) {
            ForEach(groups, id: \.0) { name, rows in SettingsGroup(name) { ForEach(rows) { $0.row } } }
        }
    }

    private var results: some View {
        let hits = items.filter { $0.matches(searchTerm) }
        return VStack(alignment: .leading, spacing: 18) {
            if hits.isEmpty {
                VStack(spacing: 4) {
                    Text("No settings match “\(searchTerm)”").font(.system(size: 13, weight: .medium))
                    Text("Try a shorter word, like “banner”, “shortcut” or “theme”.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                ForEach(Self.names.map(\.0), id: \.self) { t in
                    let inTab = hits.filter { $0.tab == t }
                    if !inTab.isEmpty {
                        ForEach(groupsIn(inTab), id: \.0) { name, rows in
                            SettingsGroup("\(Self.names.first { $0.0 == t }!.1) › \(name)") { ForEach(rows) { $0.row } }
                        }
                    }
                }
            }
        }
    }

    private func groupsIn(_ list: [Item]) -> [(String, [Item])] {
        var order: [String] = []
        for i in list where !order.contains(i.group) { order.append(i.group) }
        return order.map { g in (g, list.filter { $0.group == g }) }
    }

    // MARK: the settings

    private func item<C: View>(_ tab: Tab, _ group: String, _ title: String, _ detail: String, keywords: String = "", error: String? = nil, @ViewBuilder _ control: () -> C) -> Item {
        Item(tab: tab, group: group, title: title, detail: detail, keywords: keywords, row: AnyView(SettingRow(title, detail, error: error, control)))
    }

    /// Pages without rows (Updates, Agents, About) get one entry each, so search can send you there.
    private func jump(_ to: Tab, _ title: String, _ detail: String, keywords: String) -> Item {
        item(to, "Go to", title, detail, keywords: keywords) { Button("Open") { query = ""; tab = to }.buttonStyle(Pill()) }
    }

    private var items: [Item] {
        @Bindable var p = prefs
        let model = AppModel.shared
        func toggle(_ b: Binding<Bool>) -> some View { Toggle("", isOn: b).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
        return [
            item(.general, "Account", "Telegram account", model.session.phase == .ready ? "Signed in as \(model.session.me)." : "Not signed in. Open Hush from the menu bar to sign in.", keywords: "sign out log out login telegram") {
                Button("Sign out") { model.session.logOut() }.buttonStyle(Pill()).disabled(model.session.phase != .ready)
            },
            item(.general, "Startup", "Launch at login", "Adds Hush to Login Items. Turn it off any time.", keywords: "startup boot login items", error: prefs.launchAtLoginError) {
                toggle(Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
            },
            item(.general, "Appearance", "Theme", "Applies to the popover and this window.", keywords: "dark light system appearance color") {
                Segmented(options: ThemeChoice.allCases.map { ($0, $0.label) }, selection: $p.theme)
            },
            item(.general, "Appearance", "Chat in a window", "The menu bar icon opens a resizable chat window with your chat list on the left, instead of the small popover. The menu bar keeps the unread number.", keywords: "popover window large") {
                toggle($p.windowMode)
            },
            item(.general, "Appearance", "Dock icon", "Off by default. Hush lives in the menu bar.", keywords: "dock menu bar") { toggle($p.showDockIcon) },
            item(.general, "Performance", "Always light", "Telegram pushes updates, so Hush never polls. Messages are loaded when you open a chat and dropped when you close it.", keywords: "memory ram polling battery") {
                Badge(text: AppModel.shared.demo ? "no polling" : AppMemory.footprint, kind: .ok)
            },

            item(.notifications, "Banners", "Banners for favorites", "Star a chat inside its conversation. Starred, unmuted chats show a banner and add to the number beside the menu bar icon. Tap a banner to open that chat.", keywords: "notifications star favourite alerts badge") {
                toggle($p.banners)
            },
            item(.notifications, "Banners", "Also for all chats", "Extend banners and the menu bar number to every unmuted chat, not just favorites.", keywords: "notifications every chat alerts") {
                toggle($p.alertsForAllChats)
            },
            item(.notifications, "macOS", "macOS permission", notificationHelp(model.notificationAccess), keywords: "notifications allow blocked system settings") {
                VStack(alignment: .trailing, spacing: 6) {
                    Badge(text: notificationLabel(model.notificationAccess), kind: model.notificationAccess == .authorized ? .ok : .warn)
                    if model.notificationAccess == .denied {
                        Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }.buttonStyle(Pill())
                    } else if model.notificationAccess == .notDetermined {
                        Button("Allow") { model.requestNotificationAccess() }.buttonStyle(Pill(kind: .primary))
                    }
                }
            },
            item(.notifications, "macOS", "Test banner", "Shows a sample banner now, so you can see that notifications work.", keywords: "notifications try sample") {
                Button("Send test") { model.sendTestBanner() }.buttonStyle(Pill())
            },

            item(.shortcuts, "Global shortcuts", "Open Hush", "Show or hide the popover from anywhere. Click the box, then press the keys.", keywords: "hotkey keyboard record", error: prefs.shortcutError) { ShortcutRecorder() },
            item(.shortcuts, "Global shortcuts", "Show the stack", "Opens a focus view of unread messages from your starred chats. Click the box, then press the keys. The default is Control+Option+S.", keywords: "hotkey keyboard favorites record", error: prefs.stackShortcutError) {
                ShortcutRecorder(current: prefs.stackShortcut, fallback: .stackDefault) { prefs.setStackShortcut($0) }
            },
            item(.shortcuts, "In the chat list", "Move through chats", "Up and Down arrows move the highlight in the chat list. They stop at the first and last chat.", keywords: "keyboard arrows navigate") { Keys("↑  ↓") },
            item(.shortcuts, "In the chat list", "Open the highlighted chat", "Return opens the chat you highlighted.", keywords: "keyboard enter") { Keys("Return") },
            item(.shortcuts, "In the chat list", "Next or previous chat", "Opens the chat below or above the current one and wraps around at the ends. Works from the message box too. In the popover, Tab opens the first chat and Shift+Tab the last.", keywords: "keyboard tab switch") { Keys("Tab  ⇧Tab") },
            item(.shortcuts, "In a chat", "Send a message", "Type in the box and press Return.", keywords: "keyboard enter reply") { Keys("Return") },
            item(.shortcuts, "In the stack", "Move through the stack", "Down and Right go to the next card, Up and Left to the previous one. The stack does not wrap. Esc closes it.", keywords: "keyboard arrows favorites cards escape") { Keys("↓ → ↑ ←  Esc") },

            jump(.updates, "Check for updates", "Version, release notes and automatic updates.", keywords: "update upgrade version release download"),
            jump(.agents, "Agents (MCP)", "Let Claude and other agents read and send Telegram messages through Hush.", keywords: "mcp claude agent install tools"),
            jump(.about, "About Hush", "Version, source code and where to report an issue.", keywords: "about version github bug report issue"),
        ]
    }

    private func notificationLabel(_ s: UNAuthorizationStatus) -> String {
        switch s { case .authorized, .provisional, .ephemeral: "Allowed"; case .denied: "Blocked"; default: "Not asked" }
    }

    private func notificationHelp(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .denied: "macOS is blocking Hush. Open System Settings, Notifications, Hush, and allow banners."
        case .notDetermined: "Hush has not asked macOS yet. Press Allow to get the permission prompt."
        default: "macOS lets Hush show banners. Send a test to see one."
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.image(size: 72)).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hush").font(.system(size: 18, weight: .semibold))
                    Text("Version \(BuildInfo.current.version) · \(BuildInfo.current.shortCommit)").foregroundStyle(.secondary)
                    Text("Telegram as plain text in your menu bar, for you and your agents.").font(.system(size: 12.5))
                }
            }
            HStack(spacing: 10) {
                Link("Source on GitHub", destination: URL(string: "https://github.com/kalahroudi/hush")!)
                Link("Report an issue", destination: URL(string: "https://github.com/kalahroudi/hush/issues")!)
            }.font(.system(size: 13))
        }
    }
}

/// A key hint shown at the right of a settings row.
struct Keys: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline))
    }
}

struct SettingsGroup<C: View>: View {
    let title: String
    @ViewBuilder var content: C
    init(_ t: String, @ViewBuilder content: () -> C) { title = t; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title).padding(.leading, 4)
            VStack(spacing: 0) { content }.padding(.horizontal, 14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    var error: String?
    @ViewBuilder var control: Control
    init(_ title: String, _ detail: String?, error: String? = nil, @ViewBuilder _ control: () -> Control) { self.title = title; self.detail = detail; self.error = error; self.control = control() }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let d = detail { Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let e = error { Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.danger) }
            }
            Spacer(minLength: 8)
            control
        }.padding(.vertical, 10).overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}
