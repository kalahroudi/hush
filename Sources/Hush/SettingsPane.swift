// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import HushKit

/// RULES: every tab has content (no empty pages); every control writes straight to Prefs and takes effect at once
/// ("Settings save automatically", no Apply button); every option has a one-line explanation.
struct SettingsPane: View {
    let prefs = Prefs.shared
    @State private var tab: Tab
    enum Tab: Hashable { case general, updates, agents, about }
    init(initialTab: Tab = .general) { _tab = State(initialValue: initialTab) }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Settings") {
                EmptyView()
            } tabs: {
                TabBar(tabs: [(Tab.general, "General"), (Tab.updates, "Updates"), (Tab.agents, "Agents (MCP)"), (Tab.about, "About")], selection: $tab)
            }
            ScrollView {
                Group {
                    switch tab {
                    case .general: general
                    case .updates: UpdatesView()
                    case .agents: AgentsView()
                    case .about: about
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Text("Hush \(BuildInfo.current.version) · github.com/kalahroudi/hush"); Spacer(); Text("Settings save automatically") }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 8)
        }
    }

    private var general: some View {
        @Bindable var p = prefs
        let model = AppModel.shared
        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 18) {
                SettingsGroup("Telegram") {
                    SettingRow("Account", model.session.phase == .ready ? "Signed in as \(model.session.me)." : "Not signed in. Open Hush from the menu bar to sign in.") {
                        Button("Sign out") { model.session.logOut() }.buttonStyle(Pill()).disabled(model.session.phase != .ready)
                    }
                    SettingRow("Banners for favorites", "Star a chat inside its conversation. Only starred, unmuted chats show a banner. Everything else stays silent; the menu bar dot is the only signal.") {
                        Toggle("", isOn: $p.banners).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                    }
                }
                SettingsGroup("Startup") {
                    SettingRow("Launch at login", "Adds Hush to Login Items. Turn it off any time.", error: prefs.launchAtLoginError) { Toggle("", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) })).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
                }
            }.frame(maxWidth: .infinity)
            VStack(spacing: 18) {
                SettingsGroup("Appearance") {
                    SettingRow("Theme", "Applies to the popover and this window.") { Segmented(options: ThemeChoice.allCases.map { ($0, $0.label) }, selection: $p.theme) }
                    SettingRow("Dock icon", "Off by default. Hush lives in the menu bar.") { Toggle("", isOn: $p.showDockIcon).labelsHidden().toggleStyle(.switch).tint(Theme.accent) }
                }
                SettingsGroup("Performance") {
                    SettingRow("Always light", "Telegram pushes updates, so Hush never polls. Messages are loaded when you open a chat and dropped when you close it.") { Badge(text: AppMemory.footprint, kind: .ok) }
                }
            }.frame(maxWidth: .infinity)
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
