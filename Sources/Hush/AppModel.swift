// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import HushKit
@preconcurrency import UserNotifications

struct BackgroundTask: Identifiable {
    enum State: Equatable { case running, done, failed(String) }
    let id = UUID()
    var title: String
    var state: State = .running
    var lines: [String] = []
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var isError = false
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let action: String
    let detail: String
    let outcome: String
}

/// App-wide state. Telegram pushes events, so nothing polls; the setup checklist is re-read only while a window is visible.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let session = TelegramSession()
    var tasks: [BackgroundTask] = []
    var toast: Toast?
    var setupState = SetupState.detect()
    var activity: [ActivityEntry] = []
    var loadedOnce = false
    var onStatusChange: (() -> Void)?
    /// Set by `--snapshot` so screenshots use sample data and nothing connects.
    var demo = false
    /// A notification tap asks the popover to open this chat.
    var pendingChat: Int64?
    /// Form drafts live here, not in the views: the popover is destroyed whenever it closes, and you leave it to copy values elsewhere.
    /// Memory only, never written to disk.
    var draftKeyId = ""
    var draftKeyHash = ""
    var draftPhone = ""
    var draftCode = ""
    var draftPassword = ""
    var draftMessages: [Int64: String] = [:]

    private var popoverVisible = false

    var settings: Prefs { Prefs.shared }
    var needsSetup: Bool { !setupState.ready }
    var busy: Bool { tasks.contains { $0.state == .running } }
    var runningTask: BackgroundTask? { tasks.last { $0.state == .running } }

    /// Menu bar glyph: filled = unread, dashed = not connected, outline = all read. Shape, not colour.
    var iconState: StatusIcon.State {
        guard session.phase == .ready else { return .busy }
        if !session.online { return .busy }
        return menuBarCount > 0 ? .active : .idle
    }

    /// The number beside the menu bar glyph: unread messages in favorites, or in every unmuted chat when all chats are enabled.
    /// Favorites are counted among the chats Hush has loaded (the most recent ones).
    var menuBarCount: Int {
        guard session.phase == .ready else { return 0 }
        if settings.alertsForAllChats { return session.unread }
        return session.chats.filter { settings.isFavorite($0.id) && !$0.muted }.reduce(0) { $0 + $1.unread }
    }

    func start() {
        setupState = SetupState.detect()
        loadedOnce = true
        guard !needsSetup else { return }
        session.onIncoming = { [weak self] chat, text in self?.banner(chat, text) }
        session.start()
    }

    func setPopoverVisible(_ v: Bool) {
        popoverVisible = v
        if session.phase == .ready { draftCode = ""; draftPassword = ""; draftPhone = "" }   // sign-in finished: forget what was typed
        if v, !demo { setupState = SetupState.detect(); if !needsSetup, session.phase == .stopped { start() } }
    }

    // MARK: Banners (favorites only)

    private func banner(_ chat: ChatSummary, _ text: String) {
        guard BannerPolicy.shouldShow(enabled: settings.banners, favoritesOnly: !settings.alertsForAllChats, isFavorite: settings.isFavorite(chat.id)) else { return }
        post(title: chat.title, body: text, chat: chat.id)
    }

    private func post(title: String, body: String, chat: Int64?) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        if let chat { c.userInfo = ["chat": String(chat)] }
        let id = chat.map { "chat-\($0)" } ?? "test"   // same id: a burst shows one banner
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { error in
            if let error { Task { @MainActor in AppModel.shared.show("Banner failed: \(error.localizedDescription)", error: true) } }
        }
    }

    // MARK: Notification permission

    var notificationAccess: UNAuthorizationStatus = .notDetermined

    /// Asks macOS for permission (it prompts only once) and records the answer.
    func requestNotificationAccess() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in
            Task { @MainActor in AppModel.shared.refreshNotificationAccess() }
        }
    }

    func refreshNotificationAccess() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let status = s.authorizationStatus
            Task { @MainActor in AppModel.shared.notificationAccess = status }
        }
    }

    func sendTestBanner() {
        if notificationAccess == .notDetermined { requestNotificationAccess() }
        post(title: "Hush", body: "Notifications are working.", chat: nil)
        show(notificationAccess == .denied ? "macOS is blocking Hush notifications. Allow them in System Settings." : "Test banner sent")
    }

    // MARK: Agents

    func log(_ action: String, _ detail: String, _ outcome: String) {
        activity.insert(ActivityEntry(action: action, detail: detail, outcome: outcome), at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
    }

    // MARK: Background tasks (setup only)

    func runTask(_ title: String, after: (@MainActor (Bool) -> Void)? = nil,
                 _ work: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void) {
        let task = BackgroundTask(title: title)
        let id = task.id
        tasks.append(task)
        Task {
            let log: @Sendable (String) -> Void = { line in Task { @MainActor in
                if let i = AppModel.shared.tasks.firstIndex(where: { $0.id == id }) { AppModel.shared.tasks[i].lines.append(line) } } }
            do {
                try await work(log)
                finish(id, .done); after?(true)
            } catch {
                finish(id, .failed(error.localizedDescription)); after?(false)
            }
            setupState = SetupState.detect()
            try? await Task.sleep(for: .seconds(20))
            tasks.removeAll { $0.id == id && $0.state != .running }
        }
    }

    private func finish(_ id: UUID, _ state: BackgroundTask.State) {
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].state = state }
        if case .failed(let m) = state { show(m, error: true) } else if let t = tasks.first(where: { $0.id == id }) { show("\(t.title) finished") }
    }

    func show(_ message: String, error: Bool = false) {
        let t = Toast(message: message, isError: error)
        toast = t
        Task { try? await Task.sleep(for: .seconds(error ? 8 : 3.5)); if toast == t { toast = nil } }
    }

    // MARK: First-run setup

    func setUpEverything() {
        let state = SetupState.detect()
        runTask("Setting up Hush", after: { [weak self] ok in if ok { self?.start() } }) { log in
            if state.needsDownload { try await TDLibInstall.install(onLine: log) }
            try AppPaths().ensureDirectories()
        }
    }

    /// Saves the Telegram API key from the setup form. Returns an error message, or nil on success.
    func saveKeys(id: String, hash: String) -> String? {
        guard let keys = TelegramKeys.parse(id: id, hash: hash) else {
            return "The API ID is a number and the hash is 32 letters and digits. Copy both from my.telegram.org/apps."
        }
        draftKeyId = ""; draftKeyHash = ""
        do { try keys.save() } catch { return "Could not save the key: \(error.localizedDescription)" }
        setupState = SetupState.detect()
        start()
        return nil
    }
}
