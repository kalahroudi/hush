// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Everything that goes wrong anywhere in the app ends up here: a plain-words problem for the person,
/// a scrubbed entry in one log file, and a prefilled GitHub issue they can choose to send.
/// Reports carry the app version, macOS version and the technical error, and never anything about the person.
public enum Privacy {
    /// Removes what identifies the person or their account from text that is about to be logged or shared:
    /// home folder and user name, e-mail addresses, phone numbers, long tokens and URL query strings.
    public static func scrub(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName(), host: String = ProcessInfo.processInfo.hostName) -> String {
        var s = text
        if home.count > 1 { s = s.replacingOccurrences(of: home, with: "~") }
        s = s.replacingOccurrences(of: #"/Users/[^/\s"'\\]+"#, with: "/Users/~", options: .regularExpression)
        let rules: [(String, String)] = [
            (#"https?://[^\s?#"')]+\?[^\s"')]*"#, "<url>"),                                  // query strings carry tokens
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
            (#"\b\d{6,}:[A-Za-z0-9_-]{20,}"#, "<token>"),                                    // bot tokens
            (#"(?<![\w.])\+?\d[\d ()\-]{8,}\d(?![\w])"#, "<number>"),                      // phone numbers, ids
            (#"(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{28,}"#, "<token>"), // keys, hashes
        ]
        for (pattern, label) in rules { s = s.replacingOccurrences(of: pattern, with: label, options: .regularExpression) }
        if user.count > 2 { s = s.replacingOccurrences(of: user, with: "<user>") }
        let name = host.replacingOccurrences(of: ".local", with: "")
        if name.count > 2 { s = s.replacingOccurrences(of: name, with: "<host>") }
        return s
    }
}

public extension AppProblem {
    /// Turns any error into something a person can act on. `area` names the feature that failed.
    /// Update failures keep their own wording (`from(_:)`); everything else is classified here.
    static func from(_ error: Error, area: String) -> AppProblem {
        var p: AppProblem
        let raw = String(describing: error) + " | " + error.localizedDescription
        let tryAgain = "Nothing was lost. Try again."
        switch error {
        case is UpdateError, is ShellError: p = .from(error)
        case let e as URLError:
            p = .init(title: "Couldn't reach the internet", hint: "Check your connection and try again.", detail: "\(e.code.rawValue) \(e.localizedDescription)")
        case let e as TDError:
            let m = e.message.lowercased()
            if m.contains("not connected") { p = .init(title: "Hush isn't connected to Telegram", hint: "Wait a moment for it to reconnect, or open Settings and check the sign-in.", detail: raw) }
            else if m.contains("flood") || e.code == 429 { p = .init(title: "Telegram asks to slow down", hint: "Wait a minute and try again.", detail: raw) }
            else if m.contains("phone_code") || m.contains("password_hash") { p = .init(title: "That code or password wasn't accepted", hint: "Check it and try again.", detail: raw) }
            else { p = .init(title: "Telegram couldn't do that", hint: tryAgain, detail: raw) }
        case let e as Keychain.Failure:
            p = .init(title: "Hush couldn't use the macOS Keychain", hint: "Unlock your Keychain in Keychain Access and try again.", detail: "\(e)")
        case let e as TDLibInstall.Failure:
            p = .init(title: "Telegram's engine couldn't be installed", hint: "Check your connection and try again.", detail: "\(e)")
        case let e as CocoaError where [.fileWriteNoPermission, .fileReadNoPermission].contains(e.code):
            p = .init(title: "Hush doesn't have permission for that file", hint: "Check the folder's permissions, then try again.", detail: raw)
        default:
            p = .init(title: "Something went wrong in \(area)", hint: "\(tryAgain) If it keeps happening, press Report on GitHub.", detail: raw)
        }
        p.area = area
        return p
    }

    /// Plain text for pasting anywhere: no names, paths or account details.
    func report(step: String? = nil, build: BuildInfo = .current, system: String = Diagnostics.system, channel: String? = nil) -> String {
        Privacy.scrub("""
        Hush problem
        \(title)
        Area: \(area)\(step.map { "\nStep: \($0)" } ?? "")
        App: \(Diagnostics.app(build, channel: channel))
        System: \(system)
        Detail: \(detail)
        """)
    }

    /// One log entry: when, where, the plain message, the technical text, what was running. Scrubbed.
    func logEntry(step: String? = nil, app: String, system: String, date: Date = .now) -> String {
        let f = ISO8601DateFormatter()
        let at = step.map { " during \"\($0)\"" } ?? ""
        return Privacy.scrub("[\(f.string(from: date))] FAILED in \(area)\(at): \(title)\n  detail: \(detail.replacingOccurrences(of: "\n", with: " ⏎ "))\n  app: \(app) · \(system)\n")
    }

    /// A prefilled "new issue" page. GitHub caps URL length, so only the end of the log goes in the link;
    /// the app also copies the whole log so it can be pasted over it.
    func issueURL(repo: String, step: String? = nil, app: String, system: String, log: String, maxLog: Int = 3500) -> URL? {
        let body = Privacy.scrub("""
        **\(title)**

        - Area: \(area)\(step.map { "\n- Step: \($0)" } ?? "")
        - App: \(app)
        - System: \(system)

        <details><summary>Error log</summary>

        ```
        \(String(log.suffix(maxLog)))
        ```
        </details>

        _Sent from Hush's error report. Names, paths, e-mail addresses and numbers are removed before sending._
        """)
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")
        c?.queryItems = [.init(name: "title", value: Privacy.scrub("[\(area)] \(title)")), .init(name: "body", value: body)]
        return c?.url
    }
}

public enum Diagnostics {
    public static var system: String { "\(ProcessInfo.processInfo.operatingSystemVersionString) · \(arch)" }
    public static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
    public static func app(_ build: BuildInfo, channel: String? = nil) -> String {
        "Hush \(build.version) (\(build.shortCommit))" + (channel.map { ", channel \($0)" } ?? "")
    }
}

/// One capped log file for every failure, kept across runs. Entries are scrubbed before they are written.
public struct ErrorLog: Sendable {
    public let url: URL
    public var limit = 64_000
    public init(url: URL = AppPaths().root.appendingPathComponent("errors.log")) { self.url = url }

    public var text: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    public func append(_ entry: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String((text + entry).suffix(limit)).write(to: url, atomically: true, encoding: .utf8)
    }
}
