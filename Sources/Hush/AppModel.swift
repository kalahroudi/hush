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
    /// Set for failures: the toast then offers to copy the details or report them.
    var problem: AppProblem?
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

    /// The favorites stack: one card per favorite chat with unread messages, newest activity first.
    var stackCards: [StackCard] = []
    var stackSelection = 0
    var stackMode = StackMode.empty
    /// True while the reply field on the top card has focus or a send is running.
    var stackReplying = false {
        didSet { if !stackReplying { flushStackQueue() } }
    }
    /// True while the stack window is on screen; incoming messages only update the stack then.
    var stackOpen = false
    /// New favorite chats that arrived during a reply. They join the stack when the reply ends.
    private var stackQueued: [StackCard] = []

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
        // Sign-in typos show inline; the log keeps every failure so a report has the full picture.
        session.onIncomingLine = { [weak self] chat, line in self?.stackIncoming(chat, line) }
        session.onError = { [weak self] e in self?.record(AppProblem.from(e, area: "Telegram")) }
        session.start()
    }

    func setPopoverVisible(_ v: Bool) {
        popoverVisible = v
        if session.phase == .ready { draftCode = ""; draftPassword = ""; draftPhone = "" }   // sign-in finished: forget what was typed
        if v, !demo { setupState = SetupState.detect(); if !needsSetup, session.phase == .stopped { start() } }
    }

    // MARK: Favorites stack

    /// Builds the stack from the chats Hush has loaded. Unread lines are read from history, which marks nothing read and opens no chat.
    /// A chat whose history cannot be read still gets a card from its last message, and the failure goes to the error log.
    func loadStack() async {
        let chats = session.chats.filter { $0.unread > 0 && settings.isFavorite($0.id) }
        var fetched: [Int64: [Line]] = [:]
        for chat in chats {
            do { fetched[chat.id] = try await session.unreadLines(chatId: chat.id, count: chat.unread) }
            catch { record(AppProblem.from(error, area: "Telegram")) }
        }
        stackCards = FavoritesStack.build(chats: session.chats, isFavorite: { self.settings.isFavorite($0) }, lines: { fetched[$0] ?? [] })
        stackSelection = 0
        stackQueued = []
        stackMode = StackMode.opening(with: stackCards)
    }

    /// Updates the open stack with a message that just arrived in a favorite chat.
    private func stackIncoming(_ chat: ChatSummary, _ line: Line) {
        guard stackOpen, settings.isFavorite(chat.id) else { return }
        let r = FavoritesStack.merge(cards: stackCards, queued: stackQueued, selection: stackSelection, chat: chat, line: line, isReplying: stackReplying)
        applyStack(r)
    }

    private func flushStackQueue() {
        guard stackOpen else { return }
        applyStack(FavoritesStack.flush(cards: stackCards, queued: stackQueued, selection: stackSelection))
    }

    private func applyStack(_ r: (cards: [StackCard], queued: [StackCard], selection: Int)) {
        stackCards = r.cards; stackQueued = r.queued; stackSelection = r.selection
        if !stackCards.isEmpty { stackMode = .cards }
    }

    /// Sends the draft typed on the top card to that card's chat, then marks the chat read and drops its card.
    /// The draft comes back and the card stays if sending fails.
    func sendStackReply() {
        guard let id = FavoritesStack.replyTarget(cards: stackCards, selection: stackSelection),
              let text = draftMessages[id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draftMessages[id] = nil
        Task {
            do { try await session.send(text, to: id) }
            catch { draftMessages[id] = text; report(error, area: "Sending a message"); return }
            await finishStackCard(id)
        }
    }

    /// Brings the next or previous card to the top. It does not wrap, and it leaves the card being replied to alone.
    func stepStack(forward: Bool) {
        guard stackMode == .cards, !stackReplying else { return }
        stackSelection = FavoritesStack.step(count: stackCards.count, selection: stackSelection, forward: forward)
    }

    /// "Done": marks the top card's chat read without replying and drops its card.
    func markStackDone() {
        guard let id = FavoritesStack.replyTarget(cards: stackCards, selection: stackSelection) else { return }
        Task { await finishStackCard(id) }
    }

    /// Marks the chat read through the same path the main window uses, then removes its card. A failed mark keeps the card.
    private func finishStackCard(_ id: Int64) async {
        do { try await session.markRead(chatId: id) }
        catch { report(error, area: "Marking a chat read"); return }
        let r = FavoritesStack.dropCard(id: id, from: stackCards, selection: stackSelection)
        stackCards = r.cards; stackSelection = r.selection; stackMode = r.mode
        stackReplying = false
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
            if let error { Task { @MainActor in AppModel.shared.report(error, area: "Notifications") } }
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
                finish(id, .failed(error.localizedDescription), error: error, area: title); after?(false)
            }
            setupState = SetupState.detect()
            try? await Task.sleep(for: .seconds(20))
            tasks.removeAll { $0.id == id && $0.state != .running }
        }
    }

    private func finish(_ id: UUID, _ state: BackgroundTask.State, error: Error? = nil, area: String = "Setup") {
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].state = state }
        if case .failed(let m) = state { if let error { report(error, area: area) } else { show(m, error: true) } } else if let t = tasks.first(where: { $0.id == id }) { show("\(t.title) finished") }
    }

    func show(_ message: String, error: Bool = false, problem: AppProblem? = nil) {
        let t = Toast(message: message, isError: error, problem: problem)
        toast = t
        Task { try? await Task.sleep(for: .seconds(problem != nil ? 15 : error ? 8 : 3.5)); if toast == t { toast = nil } }
    }

    // MARK: Errors

    /// One log for every failure in the app. Entries are scrubbed of personal details as they are written.
    let errorLog = ErrorLog()
    private var appSummary: String { Diagnostics.app(.current, channel: Prefs.shared.updateChannel.rawValue) }

    /// Writes the failure to the error log without telling the person (the caller already shows it).
    func record(_ problem: AppProblem, step: String? = nil) {
        errorLog.append(problem.logEntry(step: step, app: appSummary, system: Diagnostics.system))
    }

    /// The way to handle any error: log it, and show a plain message with Copy details and Report buttons.
    @discardableResult
    func report(_ error: Error, area: String, step: String? = nil) -> AppProblem {
        let p = AppProblem.from(error, area: area)
        record(p, step: step)
        show(p.title, error: true, problem: p)
        return p
    }

    /// Puts the scrubbed error log on the clipboard (or this problem's report if nothing was logged yet).
    func copyDetails(_ p: AppProblem, step: String? = nil) {
        let log = errorLog.text
        Clipboard.copy(log.isEmpty ? p.report(step: step, channel: Prefs.shared.updateChannel.rawValue) : Privacy.scrub(log))
        show("Error details copied. Nothing personal is included.")
    }

    /// Opens a prefilled GitHub issue with the version, macOS version and the scrubbed error. The person reviews it and presses Submit.
    func sendReport(_ p: AppProblem, step: String? = nil) {
        let log = errorLog.text
        Clipboard.copy(Privacy.scrub(log))
        guard let url = p.issueURL(repo: BuildInfo.current.repo, step: step, app: appSummary, system: Diagnostics.system, log: Privacy.scrub(log)) else { return }
        NSWorkspace.shared.open(url)
        show("The full error log is copied. Paste it into the issue if more detail helps.")
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
        do { try keys.save() } catch { return report(error, area: "Setup", step: "Saving the Telegram key").title }
        setupState = SetupState.detect()
        start()
        return nil
    }
}
