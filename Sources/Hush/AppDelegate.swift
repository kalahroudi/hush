// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import HushKit
@preconcurrency import UserNotifications

/// Owns the menu bar item (with its popover arrow), the Dock presence, and the Manager window.
/// The popover's views and the window are created on demand and destroyed on close, so a closed UI holds no view memory.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotMode.dir != nil { SnapshotMode.run(); return }
        Prefs.shared.applyTheme()
        Prefs.shared.applyDockIcon()
        NSApp.applicationIconImage = AppIcon.image(size: 512, padded: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.image(.idle)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("Hush")

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        UNUserNotificationCenter.current().delegate = self
        model.start()
        watchStatus()
        startControl()
        Updater.shared.confirmLaunch()                                   // tells a pending swap script "the new version started"
        Task { Updater.shared.autoCheckIfDue(enabled: Prefs.shared.autoCheckUpdates) }
        if model.needsSetup { togglePopover() }                          // first run: show the guided setup right away
    }

    /// The popover does not follow NSApp.appearance on its own (it takes the menu bar's look), so set it explicitly.
    func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    @objc func openSettings() { showSettings() }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Open Hush", action: #selector(togglePopover), keyEquivalent: "").target = self
            m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Hush", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = m; statusItem.button?.performClick(nil); statusItem.menu = nil   // menu only for this click
        } else { togglePopover() }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        applyAppearance()
        let host = NSHostingController(rootView: PopoverView(openSettings: { [weak self] in self?.showSettings() }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        host.view.window?.makeKey()   // so the message box takes keystrokes
    }

    /// Tapping a banner opens that conversation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["chat"] as? String).flatMap { Int64($0) }
        Task { @MainActor in
            AppModel.shared.pendingChat = id
            if !self.popover.isShown { self.togglePopover() }
        }
        done()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil   // release the popover's views while hidden
    }

    func showSettings(agents: Bool = false) {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 500)
            w.setFrameAutosaveName("HushSettings")
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsPane(initialTab: agents ? .agents : .general).background(Theme.pane).ignoresSafeArea(.container, edges: .top))
            if !w.setFrameUsingName("HushSettings") { w.center() }
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        settingsWindow?.contentView = nil   // frees the SwiftUI tree
        settingsWindow = nil
    }

    // Clicking the Dock icon opens the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }; return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        control?.stop()
        Task { await model.session.closeForQuit(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Re-reads the menu bar glyph whenever unread count, connection or sign-in state changes. No timers.
    private func watchStatus() {
        statusItem.button?.image = StatusIcon.image(model.iconState)
        withObservationTracking { _ = model.iconState } onChange: { [weak self] in
            Task { @MainActor in self?.watchStatus() }
        }
    }

    // MARK: Agent bridge

    private var control: ControlServer?

    private func startControl() {
        guard !model.demo else { return }
        try? AppPaths().ensureDirectories()
        let server = ControlServer(path: AppPaths().socketFile.path) { req in await AgentBridge.handle(req) }
        try? server.start()
        control = server
    }

    // The app lives in the menu bar: closing the last window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
