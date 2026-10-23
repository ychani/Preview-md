// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient

final class TokenStoreTests: XCTestCase {

    func testInMemoryStore() async throws {
        let store = InMemoryTokenStore(initial: ["a": "uc1_a"])
        let a = try await store.token(forServer: "a")
        XCTAssertEqual(a, "uc1_a")
        try await store.setToken("uc1_b", forServer: "b")
        var all = await store.all
        XCTAssertEqual(all, ["a": "uc1_a", "b": "uc1_b"])
        try await store.setToken(nil, forServer: "a")
        all = await store.all
        XCTAssertEqual(all, ["b": "uc1_b"])
        let missing = try await store.token(forServer: "zzz")
        XCTAssertNil(missing)
    }

    /// Touches the login keychain, so it only runs with `UNIVOCAL_KEYCHAIN_TESTS=1`
    /// (CI has no unlocked keychain). Uses a throwaway service name.
    func testKeychainStoreRoundTrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIVOCAL_KEYCHAIN_TESTS"] == "1",
                          "set UNIVOCAL_KEYCHAIN_TESTS=1 to exercise the real Keychain")
        let store = KeychainTokenStore(service: "com.univocal.connect.tests.\(UUID().uuidString)")
        let server = "com.univocal.app.test"
        defer { Task { try? await store.setToken(nil, forServer: server) } }
        var t = try await store.token(forServer: server)
        XCTAssertNil(t)
        try await store.setToken("uc1_first", forServer: server)
        t = try await store.token(forServer: server)
        XCTAssertEqual(t, "uc1_first")
        try await store.setToken("uc1_second", forServer: server)
        t = try await store.token(forServer: server)
        XCTAssertEqual(t, "uc1_second")
        try await store.setToken(nil, forServer: server)
        t = try await store.token(forServer: server)
        XCTAssertNil(t)
    }
}

/// A store that blocks the way a Keychain call waiting on the macOS
/// "… wants to use your confidential information …" prompt does: on another
/// thread, deaf to task cancellation, for longer than any test.
private struct PromptingKeychain: UnivocalTokenStore {
    let token: String?
    func token(forServer serverBundleId: String) async throws -> String? {
        await Self.block()
        return token
    }
    func setToken(_ token: String?, forServer serverBundleId: String) async throws {
        await Self.block()
    }
    private static func block() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { c.resume() }
        }
    }
}

final class TokenReadTimeoutTests: UnivocalTestCase {
    /// The handshake never waits on the token store: after
    /// `tokenReadTimeout` the client says hello without a token, Univocal
    /// asks for consent again, and the granted token's write is not awaited.
    func testBlockedTokenReadDoesNotHoldTheHandshake() async throws {
        let mock = try await startServer()
        var c = UnivocalConfiguration(client: .init(id: "com.example.tests", name: "Tests", version: "1"), environment: [:])
        c.connectDirectory = dir
        c.tokenStore = PromptingKeychain(token: "uc1_seeded")
        c.tokenReadTimeout = .milliseconds(200)
        c.appLocator = { _ in nil }
        let client = UnivocalClient(configuration: c)
        let started = ContinuousClock.now
        let info = try await client.connect(launchIfNeeded: false)
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .seconds(3), "the handshake waited for the token store")
        XCTAssertEqual(info.bundleId, "com.univocal.mock")
        let log = await mock.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("token=absent"), "hello should go out without the unreadable token")
        await client.disconnect()
    }

    /// Connect at launch: a blocked read means "no token" — nil, quickly,
    /// and no consent prompt.
    func testBlockedTokenReadMakesQuietConnectReturnNil() async throws {
        let mock = try await startServer()
        var c = UnivocalConfiguration(client: .init(id: "com.example.tests", name: "Tests", version: "1"), environment: [:])
        c.connectDirectory = dir
        c.tokenStore = PromptingKeychain(token: "uc1_seeded")
        c.tokenReadTimeout = .milliseconds(200)
        let client = UnivocalClient(configuration: c)
        let started = ContinuousClock.now
        let info = try await client.connectIfAuthorized()
        XCTAssertNil(info)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        let pending = await mock.pendingConsentCount
        XCTAssertEqual(pending, 0)
    }

    /// Tokens for a server in a non-default connect directory (a mock, a
    /// test) never share the real Univocal's Keychain account.
    func testTokenAccountIncludesAnOverriddenConnectDirectory() {
        var c = UnivocalConfiguration(client: .init(id: "a", name: "a", version: "1"), environment: [:])
        XCTAssertEqual(c.tokenAccount, "com.univocal.app")
        c.connectDirectory = URL(fileURLWithPath: "/tmp/uc-qa", isDirectory: true)
        XCTAssertEqual(c.tokenAccount, "com.univocal.app@/tmp/uc-qa")
        let env = UnivocalConfiguration(client: .init(id: "a", name: "a", version: "1"),
                                        environment: ["UNIVOCAL_CONNECT_DIR": "/tmp/uc-qa2"])
        XCTAssertEqual(env.tokenAccount, "com.univocal.app@/tmp/uc-qa2")
        let dev = UnivocalConfiguration(client: .init(id: "a", name: "a", version: "1"),
                                        environment: ["UNIVOCAL_BUNDLE_ID": "com.univocal.app.dev"])
        XCTAssertEqual(dev.tokenAccount, "com.univocal.app.dev")
    }
}
