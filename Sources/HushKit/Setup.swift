// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One thing the app needs before it is useful: a tool, a runtime, a first-run resource.
/// The setup screen renders these as a checklist and does everything it can by itself.
/// Whatever it cannot do (admin password, a licence click, a system permission) becomes a manual step
/// with a copyable command, so nothing is ever left as "go read the README".
public struct Prereq: Identifiable, Equatable, Sendable {
    public enum Install: Equatable, Sendable {
        case brew(String)               // `brew install <formula>`, automated
        case command(String)            // runs in the user's terminal (needs a password or a TTY)
        case link(String)               // a download page; the user does it, then presses "check again"
        case credentials(String)        // values only the user can get; the setup screen shows a form, the string is the page to get them
        case none                       // nothing to install; only detected (e.g. a first-run resource)
    }
    public let id: String
    public let title: String
    public let detail: String           // why it is needed, in one plain sentence
    public let install: Install
    public var isMet: Bool

    public init(id: String, title: String, detail: String, install: Install, isMet: Bool) {
        self.id = id; self.title = title; self.detail = detail; self.install = install; self.isMet = isMet
    }
}

public struct SetupState: Equatable, Sendable {
    public var items: [Prereq]
    public init(items: [Prereq]) { self.items = items }

    /// What Hush needs before it can show a single message, in install order.
    public static func detect() -> SetupState {
        let haveLib = TDLib.locate() != nil
        var items: [Prereq] = [
            Prereq(id: "brew", title: "Homebrew", detail: "Installs TDLib, Telegram's official library, in one command.",
                   install: .command(homebrewInstallCommand), isMet: Shell.find("brew") != nil),
            Prereq(id: "tdlib", title: "TDLib", detail: "Telegram's official client library. Hush loads it at runtime, so Hush itself stays tiny.",
                   install: .brew("tdlib"), isMet: haveLib),
            Prereq(id: "keys", title: "Telegram API key", detail: "A free API ID and hash from Telegram. They identify this app, not your account.",
                   install: .credentials(TelegramKeys.pageURL), isMet: TelegramKeys.load() != nil),
        ]
        if haveLib { items.removeAll { $0.id == "brew" } }   // nothing left to install with it, so do not show it
        return SetupState(items: items)
    }

    public var missing: [Prereq] { items.filter { !$0.isMet } }
    public var ready: Bool { missing.isEmpty }
    public var brewFormulae: [String] { missing.compactMap { if case .brew(let f) = $0.install { f } else { nil } } }
    public var homebrewPresent: Bool { Shell.find("brew") != nil }
    /// Can the app install everything missing by itself?
    public var canAutoInstall: Bool {
        !brewFormulae.isEmpty && homebrewPresent
    }
    /// One line the user can paste into Terminal to do the automated part by hand.
    public var manualCommand: String { brewFormulae.isEmpty ? "" : "brew install " + brewFormulae.joined(separator: " ") }

    /// The official Homebrew installer. It asks for a password, so it runs in a terminal, never silently.
    public static let homebrewInstallCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    /// Runs `brew install` for the missing formulae and streams its output.
    public static func installMissing(_ formulae: [String], onLine: @escaping @Sendable (String) -> Void) async throws {
        guard !formulae.isEmpty else { return }
        let env = ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ANALYTICS": "1"]
        let status = try await Shell.stream("brew", ["install"] + formulae, env: env, onLine: onLine)
        if status != 0 { throw ShellError.failed(command: "brew install", status: status, stderr: "brew install \(formulae.joined(separator: " ")) failed. See the log for details.") }
    }
}
