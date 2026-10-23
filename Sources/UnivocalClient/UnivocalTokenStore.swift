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
/// `com.univocal.connect` by default, account = `UnivocalConfiguration.tokenAccount`
/// (SPEC §9.1).
///
/// An item written by a differently signed build of the app (ad-hoc and dev
/// builds change their designated requirement on every build) makes macOS
/// ask the user before handing it over, and the call blocks until they
/// answer. So the calls run on a background queue, never on the caller's
/// thread, and `UnivocalClient` bounds the read with `tokenReadTimeout` and
/// never awaits a write on the handshake path.
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
        try await Self.offThread { try readToken(account: serverBundleId) }
    }

    public func setToken(_ token: String?, forServer serverBundleId: String) async throws {
        try await Self.offThread { try writeToken(token, account: serverBundleId) }
    }

    /// SecItem calls block (and, interactively, wait for the user): keep them
    /// off Swift's cooperative pool.
    private static func offThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try work() })
            }
        }
    }

    private func readToken(account serverBundleId: String) throws -> String? {
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

    private func writeToken(_ token: String?, account serverBundleId: String) throws {
        let q = baseQuery(account: serverBundleId)
        guard let token else {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, "delete") }
            return
        }
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            // Another build's item the user would not let us change: replace
            // it when macOS lets us delete it, else give up (the next connect
            // asks for consent again).
            status = SecItemDelete(q as CFDictionary)
            if status == errSecSuccess { status = errSecItemNotFound }
        }
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
