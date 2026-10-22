// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import ServiceManagement
import AppKit
import HushKit

enum ThemeChoice: String, CaseIterable { case system, light, dark
    var label: String { rawValue.capitalized }
}
enum UpdateChannel: String, CaseIterable { case releases, main
    var label: String { self == .releases ? "Releases" : "Main branch" }
}

/// User preferences, stored in UserDefaults. Add a property here, a `register(defaults:)` entry, and a row in SettingsPane:
/// a preference that has no row in Settings does not exist.
@MainActor @Observable
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    var theme: ThemeChoice { didSet { d.set(theme.rawValue, forKey: "theme"); applyTheme() } }
    var showDockIcon: Bool { didSet { d.set(showDockIcon, forKey: "showDockIcon"); applyDockIcon() } }
    var banners: Bool { didSet { d.set(banners, forKey: "banners") } }
    /// Off by default: only starred chats raise banners and count in the menu bar. On: every unmuted chat does.
    /// Off by default: the menu bar item opens the popover. On: it opens a resizable chat window with the chat list beside the conversation.
    var windowMode: Bool { didSet { d.set(windowMode, forKey: "windowMode"); (NSApp.delegate as? AppDelegate)?.windowModeChanged() } }
    var alertsForAllChats: Bool { didSet { d.set(alertsForAllChats, forKey: "alertsForAllChats") } }
    var agentsCanRead: Bool { didSet { d.set(agentsCanRead, forKey: "agentsCanRead") } }
    private(set) var favorites: Set<Int64>
    private(set) var shortcut: Shortcut?
    private(set) var shortcutError: String?
    private(set) var stackShortcut: Shortcut?
    private(set) var stackShortcutError: String?
    private let stackStore = ShortcutStore(key: "stackShortcut", fallback: .stackDefault)
    var updateChannel: UpdateChannel { didSet { d.set(updateChannel.rawValue, forKey: "updateChannel") } }
    var autoCheckUpdates: Bool { didSet { d.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }

    /// Launch at login is on by default; the user can turn it off. Backed by SMAppService (Login Items).
    private(set) var launchAtLogin: Bool = false
    private(set) var launchAtLoginError: String?

    private init() {
        d.register(defaults: ["banners": true, "agentsCanRead": true, "showDockIcon": false, "autoCheckUpdates": true])
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        showDockIcon = d.bool(forKey: "showDockIcon")
        banners = d.bool(forKey: "banners")
        windowMode = d.bool(forKey: "windowMode")
        alertsForAllChats = d.bool(forKey: "alertsForAllChats")
        agentsCanRead = d.bool(forKey: "agentsCanRead")
        favorites = Set((d.array(forKey: "favorites") as? [NSNumber] ?? []).map(\.int64Value))
        autoCheckUpdates = d.bool(forKey: "autoCheckUpdates")
        updateChannel = UpdateChannel(rawValue: d.string(forKey: "updateChannel") ?? "") ?? .releases
        // First run: opt in to launch at login. After that the user's choice always wins.
        if !d.bool(forKey: "launchAtLoginDefaulted") {
            d.set(true, forKey: "launchAtLoginDefaulted")
            setLaunchAtLogin(true)
        }
        refreshLaunchAtLogin()
        // First run gets the default shortcut. After that, "None" is a valid choice and is remembered.
        if d.object(forKey: "shortcutSet") == nil { shortcut = .default }
        else { shortcut = d.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } }
        stackShortcut = stackStore.load()
    }

    func setShortcut(_ s: Shortcut?) {
        if let why = ShortcutStore.rejection(of: s, against: stackShortcut, otherName: "show the stack") { shortcutError = why; return }
        shortcut = s
        d.set(true, forKey: "shortcutSet")
        d.set(s.flatMap { try? JSONEncoder().encode($0) }, forKey: "shortcut")
        shortcutError = HotKey.apply(s)
    }

    /// Stores the stack shortcut, unless it would clash with the open-Hush one; then the old value stays and the error says why.
    /// Registering it with Carbon comes with the stack window.
    func setStackShortcut(_ s: Shortcut?) {
        if let why = ShortcutStore.rejection(of: s, against: shortcut, otherName: "open Hush") { stackShortcutError = why; return }
        stackShortcut = s
        stackStore.save(s)
        stackShortcutError = nil
    }

    func isFavorite(_ id: Int64) -> Bool { favorites.contains(id) }
    func toggleFavorite(_ id: Int64) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        d.set(favorites.map { NSNumber(value: $0) }, forKey: "favorites")
    }

    func setFavoriteForDemo(_ id: Int64) { favorites.insert(id) }   // screenshots only; not persisted

    func refreshLaunchAtLogin() { launchAtLogin = SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = AppModel.shared.report(error, area: "Login Items").title
        }
        refreshLaunchAtLogin()
    }

    /// Applies to every window AND the popover (which needs the explicit nudge in AppDelegate.applyAppearance).
    func applyTheme() {
        NSApp?.appearance = switch theme { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
        (NSApp?.delegate as? AppDelegate)?.applyAppearance()
    }

    /// Dock icon on = regular app (Dock, Cmd-Tab). Off = menu bar only.
    func applyDockIcon() {
        NSApp?.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
}
