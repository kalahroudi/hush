// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Minimal generic-password Keychain access. Secrets never go to UserDefaults or logs.
public enum Keychain {
    public enum Failure: Error, LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? { if case .status(let s) = self { "Keychain error \(s)." } else { nil } }
    }
    static let service = "com.kalahroudi.hush"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// nil when the item does not exist; throws on any other failure so callers never mistake "denied" for "empty".
    public static func get(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw Failure.status(s) }
        return out as? Data
    }

    public static func set(_ account: String, _ data: Data) throws {
        let s = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if s == errSecItemNotFound {
            var q = query(account); q[kSecValueData as String] = data
            let a = SecItemAdd(q as CFDictionary, nil)
            guard a == errSecSuccess else { throw Failure.status(a) }
        } else if s != errSecSuccess { throw Failure.status(s) }
    }

    public static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
