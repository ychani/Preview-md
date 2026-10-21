// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import Security

/// Where the client keeps the grant token Univocal issued (SPEC §5.3, §9.1).
public protocol UnivocalTokenStore: Sendable {
    func token(forServer serverBundleId: String) async throws -> String?
    /// `nil` removes the token.
    func setToken(_ token: String?, forServer serverBundleId: String) async throws
}

/// Keychain-backed store: `kSecClassGenericPassword`, service
/// `com.univocal.connect` by default, account = server bundle id (SPEC §9.1).
public struct KeychainTokenStore: UnivocalTokenStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "com.univocal.connect", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func token(forServer serverBundleId: String) async throws -> String? {
        var q = baseQuery(account: serverBundleId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status, "read")
        }
    }

    public func setToken(_ token: String?, forServer serverBundleId: String) async throws {
        let q = baseQuery(account: serverBundleId)
        guard let token else {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, "delete") }
            return
        }
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Univocal Connect token (\(serverBundleId))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.error(status, "write") }
    }

    private static func error(_ status: OSStatus, _ op: String) -> UnivocalError {
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return UnivocalError(code: .internalError, message: "Keychain \(op) failed: \(text)")
    }
}

/// Process-local store for tests, previews and CLIs that should not persist.
public actor InMemoryTokenStore: UnivocalTokenStore {
    private var tokens: [String: String]

    public init(initial: [String: String] = [:]) {
        tokens = initial
    }

    public var all: [String: String] { tokens }

    public func token(forServer serverBundleId: String) async throws -> String? {
        tokens[serverBundleId]
    }

    public func setToken(_ token: String?, forServer serverBundleId: String) async throws {
        tokens[serverBundleId] = token
    }
}
