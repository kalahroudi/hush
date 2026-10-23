// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import HushKit

/// `Hush --snapshot <dir>` renders the app's screens to PNG files for the docs, then exits.
/// It uses made-up sample data, never the user's real data. Add a Shot per screen/theme you want in the README.
enum SnapshotMode {
    nonisolated(unsafe) static var dir: String?

    @MainActor static func run() {
        guard let dir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        Demo.install()
        Task { @MainActor in
            for shot in shots { await render(shot, to: dir) }
            exit(0)
        }
    }

    struct Shot { let name: String; let dark: Bool; let size: CGSize; let make: @MainActor () -> AnyView }

    @MainActor static var shots: [Shot] {
        func pop(_ name: String, dark: Bool = false, _ prepare: @escaping @MainActor () -> Void) -> Shot {
            Shot(name: name + (dark ? "-dark" : ""), dark: dark, size: CGSize(width: 620, height: 560)) { prepare(); return AnyView(PopoverShot()) }
        }
        func settings(_ name: String, dark: Bool = false, agents: Bool = false) -> Shot {
            Shot(name: name + (dark ? "-dark" : ""), dark: dark, size: CGSize(width: 820, height: 560)) {
                AnyView(SettingsPane(initialTab: agents ? .agents : .general).background(Theme.pane))
            }
        }
        func window(_ name: String, dark: Bool = false) -> Shot {
            Shot(name: name + (dark ? "-dark" : ""), dark: dark, size: CGSize(width: 780, height: 520)) { Demo.thread(); return AnyView(ChatWindowView(openSettings: {})) }
        }
        func stack(_ name: String, dark: Bool = false) -> Shot {
            Shot(name: name + (dark ? "-dark" : ""), dark: dark, size: CGSize(width: 560, height: 440)) {
                Demo.stack()
                return AnyView(StackView(close: {}).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: dark ? 0.1 : 0.82)))
            }
        }
        return [stack("stack"), stack("stack", dark: true), window("window"), window("window", dark: true), pop("inbox", Demo.inbox), pop("inbox", dark: true, Demo.inbox), pop("thread", Demo.thread), pop("thread", dark: true, Demo.thread),
                pop("setup", Demo.setup), settings("settings"), settings("settings", dark: true), settings("agents", agents: true)]
    }

    @MainActor static func render(_ shot: Shot, to dir: String) async {
        let host = NSHostingView(rootView: shot.make().frame(width: shot.size.width, height: shot.size.height))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: shot.size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -4000, y: 0))   // off screen, but still laid out and drawn
        win.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(shot.name + ".png")) }
        win.orderOut(nil)
    }
}

/// A menu bar with the popover hanging from the icon, on a soft backdrop. Used only for screenshots.
struct PopoverShot: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(red: 0.62, green: 0.71, blue: 0.78), Color(red: 0.29, green: 0.37, blue: 0.49)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Finder").bold(); Text("File"); Text("Edit"); Text("View")
                    Spacer()
                    Image(nsImage: StatusIcon.image(.active)).renderingMode(.template).padding(.horizontal, 6).padding(.vertical, 2).background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    Text("Tue 20 Oct  9:41")
                }.font(.system(size: 13)).foregroundStyle(.primary).padding(.horizontal, 14).frame(height: 28).background(.regularMaterial)
                PopoverView(openSettings: {})
                    .clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.15)))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12).padding(.top, 8).padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
            }
        }
    }
}

/// Made-up data that looks like a typical day.
@MainActor enum Demo {
    static func install() {
        let m = AppModel.shared
        m.demo = true
        m.loadedOnce = true
    }

    private static let chats: [ChatSummary] = {
        func at(_ h: Int, _ m: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: .now) ?? .now }
        return [
            ChatSummary(id: 1, title: "Mara", lastText: "ok see you at 7", lastDate: at(9, 38), unread: 2, order: 90),
            ChatSummary(id: 2, title: "Build alerts", lastText: "main: release job passed", lastDate: at(9, 12), unread: 1, order: 80),
            ChatSummary(id: 3, title: "Dad", lastText: "Call me when you land", lastDate: at(8, 50), order: 70),
            ChatSummary(id: 4, title: "Studio team", lastText: "Jo: pushed the new mockups", lastDate: at(7, 5), unread: 5, muted: true, order: 60),
            ChatSummary(id: 5, title: "Flat 4B", lastText: "Boiler guy comes Thursday", lastDate: Calendar.current.date(byAdding: .day, value: -2, to: .now), order: 50),
            ChatSummary(id: 6, title: "Sam", lastText: "[photo] the view from the roof", lastDate: Calendar.current.date(byAdding: .day, value: -3, to: .now), order: 40),
        ]
    }()

    static func inbox() {
        install()
        AppModel.shared.setupState = SetupState(items: [])
        AppModel.shared.session.loadDemo(chats: chats, unread: 3, lines: [], open: nil)
        Prefs.shared.setFavoriteForDemo(1)
    }

    static func thread() {
        inbox()
        func at(_ m: Int) -> Date { Calendar.current.date(bySettingHour: 9, minute: m, second: 0, of: .now) ?? .now }
        AppModel.shared.session.loadDemo(chats: chats, unread: 2, lines: [
            Line(id: 1, date: at(30), sender: "Mara", text: "are you free tonight?", outgoing: false),
            Line(id: 2, date: at(31), sender: "You", text: "yes, what time", outgoing: true),
            Line(id: 3, date: at(37), sender: "Mara", text: "dinner at that place on Hale St", outgoing: false),
            Line(id: 4, date: at(37), sender: "Mara", text: "[photo] menu", outgoing: false),
            Line(id: 5, date: at(38), sender: "Mara", text: "ok see you at 7", outgoing: false),
        ], open: chats[0])
    }

    /// Three favorite chats with unread messages, as the stack shows them.
    static func stack() {
        install()
        func at(_ h: Int, _ m: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: .now) ?? .now }
        func card(_ id: Int64, _ title: String, _ unread: Int, _ sender: String, _ text: String, _ date: Date) -> StackCard {
            StackCard(id: id, title: title, unread: unread, lines: [Line(id: id, date: date, sender: sender, text: text, outgoing: false)], sender: sender, text: text, date: date)
        }
        let m = AppModel.shared
        m.stackCards = [
            card(1, "Mara", 2, "Mara", "dinner at that place on Hale St, ok see you at 7", at(9, 38)),
            card(2, "Build alerts", 1, "CI", "main: release job passed", at(9, 12)),
            card(3, "Dad", 1, "Dad", "Call me when you land", at(8, 50)),
        ]
        m.stackSelection = 0
        m.stackMode = .cards
    }

    static func setup() {
        install()
        AppModel.shared.setupState = SetupState(items: [
            Prereq(id: "tdlib", title: "TDLib", detail: "Telegram's official client library. Hush keeps its own copy, so nothing global is installed.", install: .download, isMet: true),
            Prereq(id: "keys", title: "Telegram API key", detail: "A free API ID and hash from Telegram. They identify this app, not your account.", install: .credentials(TelegramKeys.pageURL), isMet: false),
        ])
    }
}
