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
