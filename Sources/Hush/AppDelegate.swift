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
    /// Created on open and dropped on close: a retained popover keeps its window and backing surfaces alive.
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotMode.dir != nil { SnapshotMode.run(); return }
        // An uncaught Objective-C exception ends the app; leave a scrubbed note so the next launch can be reported.
        NSSetUncaughtExceptionHandler { e in
            let p = AppProblem(area: "Crash", title: "Hush quit unexpectedly", hint: "", detail: "\(e.name.rawValue): \(e.reason ?? "") \(e.callStackSymbols.prefix(8).joined(separator: " | "))")
            ErrorLog().append(p.logEntry(app: Diagnostics.app(.current), system: Diagnostics.system))
        }
        Prefs.shared.applyTheme()
        Prefs.shared.applyDockIcon()
        NSApp.applicationIconImage = AppIcon.image(size: 512, padded: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.image(.idle)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("Hush")

        UNUserNotificationCenter.current().delegate = self
        model.requestNotificationAccess()   // asks once; without it macOS silently drops every banner
        model.start()
        HotKey.onPress = { [weak self] in self?.toggleMain() }
        Prefs.shared.setShortcut(Prefs.shared.shortcut)   // registers the saved (or default) shortcut
        watchStatus()
        startControl()
        Updater.shared.confirmLaunch()                                   // tells a pending swap script "the new version started"
        Task { Updater.shared.autoCheckIfDue(enabled: Prefs.shared.autoCheckUpdates) }
        if model.needsSetup { togglePopover() }                          // first run: show the guided setup right away
    }

    /// The popover does not follow NSApp.appearance on its own (it takes the menu bar's look), so set it explicitly.
    func applyAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        popover?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    @objc func openSettings() { showSettings() }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Open Hush", action: #selector(toggleMain), keyEquivalent: "").target = self
            m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Hush", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = m; statusItem.button?.performClick(nil); statusItem.menu = nil   // menu only for this click
        } else { toggleMain() }
    }

    /// Window mode applies once setup is done; first-run setup always uses the popover.
    private var useWindow: Bool { Prefs.shared.windowMode && !model.needsSetup }
    private var chatWindow: NSWindow?

    @objc private func toggleMain() {
        if !useWindow { togglePopover(); return }
        if let w = chatWindow, w.isVisible, w.isKeyWindow { w.performClose(nil) } else { showChatWindow() }
    }

    // MARK: Favorites stack

    private var stackWindow: NSPanel?
    private var previousApp: NSRunningApplication?

    /// Opens the stack, or closes it when it is already open. A stack with nothing to show opens in its empty state.
    func toggleStack() {
        if stackWindow != nil { closeStack(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        Task {
            if !model.demo { await model.loadStack() }
            showStack()
        }
    }

    private func showStack() {
        guard stackWindow == nil else { return }
        let w = StackPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.delegate = self
        w.contentView = NSHostingView(rootView: StackView(close: { [weak self] in self?.closeStack() }))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame { w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2)) } else { w.center() }
        stackWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func closeStack() {
        stackWindow?.close()
    }

    func windowModeChanged() { if !Prefs.shared.windowMode { chatWindow?.performClose(nil) } }

    func showChatWindow() {
        popover?.performClose(nil)
        if chatWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Hush"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 560, height: 420)
            w.setFrameAutosaveName("HushChat")
            w.delegate = self
            w.contentView = NSHostingView(rootView: ChatWindowView(openSettings: { [weak self] in self?.showSettings() }))
            if !w.setFrameUsingName("HushChat") { w.center() }
            chatWindow = w
        }
        chatWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover() {
        if let p = popover, p.isShown { p.performClose(nil); return }
        guard let button = statusItem.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        self.popover = popover
        applyAppearance()
        let host = NSHostingController(rootView: PopoverView(openSettings: { [weak self] in self?.showSettings() }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        host.view.window?.makeKey()   // so the message box takes keystrokes
    }

    /// Show banners even while Hush is the active app (for example with the popover open); macOS hides them otherwise.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }

    /// Tapping a banner opens that conversation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["chat"] as? String).flatMap { Int64($0) }
        Task { @MainActor in
            AppModel.shared.pendingChat = id
            if self.useWindow { self.showChatWindow() } else if self.popover?.isShown != true { self.togglePopover() }
        }
        done()
    }

    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil   // release the popover's views while hidden
        popover = nil                          // and its window, so no backing surfaces linger
        Task {                                 // let the views deinit, then hand freed heap pages back to the OS
            try? await Task.sleep(for: .milliseconds(300))
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    func showSettings(agents: Bool = false) {
        popover?.performClose(nil)
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
        let closing = notification.object as? NSWindow
        if closing === chatWindow {
            chatWindow?.contentView = nil   // frees the SwiftUI tree and closes the open chat
            chatWindow = nil
            Task { try? await Task.sleep(for: .milliseconds(300)); malloc_zone_pressure_relief(nil, 0) }
            return
        }
        if closing === stackWindow {
            stackWindow?.contentView = nil
            stackWindow = nil
            previousApp?.activate()   // hand the keyboard back to whatever the user was in
            previousApp = nil
            return
        }
        guard closing === settingsWindow else { return }
        settingsWindow?.contentView = nil   // frees the SwiftUI tree
        settingsWindow = nil
    }

    // Clicking the Dock icon opens the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if useWindow { showChatWindow() } else if popover?.isShown != true { togglePopover() }; return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        control?.stop()
        Task { await model.session.closeForQuit(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Re-reads the menu bar glyph whenever unread count, connection or sign-in state changes. No timers.
    private func watchStatus() {
        statusItem.button?.image = StatusIcon.image(model.iconState)
        let n = model.menuBarCount
        statusItem.button?.title = n > 0 ? " \(n > 99 ? "99+" : String(n))" : ""
        statusItem.button?.imagePosition = n > 0 ? .imageLeading : .imageOnly
        statusItem.length = n > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        withObservationTracking { _ = model.iconState; _ = model.menuBarCount } onChange: { [weak self] in
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
