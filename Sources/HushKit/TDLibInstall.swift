// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

/// Private install of Telegram's TDLib: one dylib under Application Support, checked against a published SHA-256.
/// No Homebrew, no admin rights, and removing Hush's folder removes it. Built by scripts/build-tdlib.sh.
public enum TDLibInstall {
    public static let version = "1.8.69"
    public static var asset: String { "libtdjson-\(version)-macos-arm64.tar.gz" }
    public static var baseURL: String { "https://github.com/kalahroudi/hush/releases/download/tdlib-\(version)" }
    public static func target(_ paths: AppPaths = AppPaths()) -> URL { paths.root.appendingPathComponent("lib/libtdjson.dylib") }

    public enum Failure: LocalizedError {
        case checksum, missing
        public var errorDescription: String? {
            switch self {
            case .checksum: "The TDLib download did not match its checksum, so Hush did not install it. Try again."
            case .missing: "The download did not contain libtdjson.dylib."
            }
        }
    }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// First hex token of a `shasum` line.
    public static func expectedHash(from text: String) -> String? { text.split(whereSeparator: \.isWhitespace).first.map(String.init) }

    public static func install(paths: AppPaths = AppPaths(), onLine: @escaping @Sendable (String) -> Void) async throws {
        try paths.ensureDirectories()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hush-tdlib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tar = tmp.appendingPathComponent(asset)
        onLine("Downloading TDLib \(version)…")
        let st = try await Shell.stream("curl", ["-fL", "--progress-bar", "-o", tar.path, "\(baseURL)/\(asset)"], onLine: onLine)
        guard st == 0 else { throw ShellError.failed(command: "curl", status: st, stderr: "Could not download TDLib. Check your connection and try again.") }
        let sumText = try await Shell.check("curl", ["-fsSL", "\(baseURL)/\(asset).sha256"], timeout: 60)
        guard let expected = expectedHash(from: sumText), try sha256(of: tar) == expected else { throw Failure.checksum }
        onLine("Checksum OK")
        try await Shell.check("tar", ["-xzf", tar.path, "-C", tmp.path], timeout: 120)
        let extracted = tmp.appendingPathComponent(asset.replacingOccurrences(of: ".tar.gz", with: "")).appendingPathComponent("libtdjson.dylib")
        guard FileManager.default.fileExists(atPath: extracted.path) else { throw Failure.missing }
        let dest = target(paths)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: extracted, to: dest)
        _ = try? await Shell.run("xattr", ["-dr", "com.apple.quarantine", dest.path], timeout: 10)
        onLine("Installed TDLib \(version)")
    }
}
