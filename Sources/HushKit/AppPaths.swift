// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Every file the app owns lives under one folder, so uninstalling is deleting it.
/// Never scatter state across ~/.something, /tmp and UserDefaults without listing it here.
public struct AppPaths: Sendable {
    public let root: URL

    /// `HUSH_HOME` moves everything (tests and the MCP probe use it); it must be short, a Unix socket path holds about 100 bytes.
    public init(root: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["HUSH_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        self.root = root ?? override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hush", isDirectory: true)
    }

    public var updateDir: URL { root.appendingPathComponent("update", isDirectory: true) }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var apiKeysFile: URL { root.appendingPathComponent("telegram-api.json") }
    /// TDLib's own database (chat list cache and the encrypted session).
    public var tdDir: URL { root.appendingPathComponent("td", isDirectory: true) }
    /// Unix socket the running app listens on so the MCP server can reach it. Owner-only.
    public var socketFile: URL { root.appendingPathComponent("hush.sock") }

    public func ensureDirectories() throws {
        for dir in [root, updateDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }
}
