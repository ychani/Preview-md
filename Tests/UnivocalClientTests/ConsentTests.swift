// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient
import UnivocalMock

final class ConsentTests: UnivocalTestCase {

    private let server = "com.univocal.app"

    // MARK: Grant / deny / timeout (S12, C5)

    func testAutoGrantStoresTokenKeyedByServerBundleId() async throws {
        let mock = try await startServer()
        let store = InMemoryTokenStore()
        let client = makeClient(store: store)
        _ = try await client.connect()
        let all = await store.all
        let issued = await mock.issuedTokens
        XCTAssertEqual(all, [server: issued[0]])
        // S16: 32 random bytes, base64url, uc1_ prefix.
        XCTAssertTrue(issued[0].hasPrefix("uc1_"))
        XCTAssertEqual(issued[0].count, 4 + 43)
        XCTAssertNil(issued[0].dropFirst(4).first { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        let log = await mock.log
        XCTAssertFalse(log.contains { $0.contains(issued[0]) }, "tokens are never logged")
    }

    func testRawConsentOrderIsPendingGrantedWelcome() async throws {
        let mock = try await startServer()
        let r = try await raw(mock)
        try r.send(Self.hello())
        let p = try await r.nextAsync(timeout: 5)
        XCTAssertEqual(p?.messageType, "consentPending")
        XCTAssertEqual(p?.int("timeoutSeconds"), 120)
        let g = try await r.nextAsync(timeout: 5)
        XCTAssertEqual(g?.messageType, "consentGranted")
        XCTAssertEqual(g?.string("requestId"), p?.string("requestId"))
        let w = try await r.nextAsync(timeout: 5)
        XCTAssertEqual(w?.messageType, "welcome", "consentGranted is immediately followed by welcome")
    }

    func testDenialThrowsAndStoresNothing() async throws {
        _ = try await startServer { $0.consent = .autoDeny(reason: "user") }
        let store = InMemoryTokenStore()
        let client = makeClient(store: store)
        do {
            _ = try await client.connect()
            XCTFail("expected consentDenied")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .consentDenied)
            XCTAssertEqual(e.reason, "user")
        }
        let all = await store.all
        XCTAssertTrue(all.isEmpty)
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
        let last = await client.lastError
        XCTAssertEqual(last?.code, .consentDenied)
    }

    func testDisabledSwitchIsReportedAsReason() async throws {
        _ = try await startServer { $0.consent = .autoDeny(reason: "disabled") }
        let client = makeClient()
        do {
            _ = try await client.connect()
            XCTFail("expected consentDenied")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.reason, "disabled")
        }
    }

    func testGrantAfterDelayShowsAwaitingConsent() async throws {
        _ = try await startServer { $0.consent = .grantAfter(.milliseconds(200)) }
        let client = makeClient()
        let states = Recorder.start(client.stateUpdates())
        let connect = Task { try await client.connect() }
        try await states.wait("awaitingConsent") { $0.last == .awaitingConsent }
        _ = try await connect.value
        try await states.wait("connected") { $0.contains { if case .connected = $0 { return true } else { return false } } }
    }

    func testManualGrantAndDenyHooks() async throws {
        let mock = try await startServer { $0.consent = .timeout }
        let client = makeClient()
        let states = Recorder.start(client.stateUpdates())
        let connect = Task { try await client.connect() }
        try await states.wait("awaitingConsent") { $0.last == .awaitingConsent }
        let pending = await mock.pendingConsentCount
        XCTAssertEqual(pending, 1)
        await mock.grantPending()
        _ = try await connect.value

        let other = makeClient(id: "com.example.other")
        let otherStates = Recorder.start(other.stateUpdates())
        let denied = Task { try await other.connect() }
        try await otherStates.wait("awaitingConsent") { $0.last == .awaitingConsent }
        await mock.denyPending()
        do {
            _ = try await denied.value
            XCTFail("expected consentDenied")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .consentDenied)
        }
    }

    func testServerSideConsentTimeout() async throws {
        _ = try await startServer {
            $0.consent = .timeout
            $0.consentTimeout = .milliseconds(200)
        }
        let client = makeClient()
        do {
            _ = try await client.connect()
            XCTFail("expected consentDenied(timeout)")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .consentDenied)
            XCTAssertEqual(e.reason, "timeout")
        }
    }

    func testClientSideConsentTimeout() async throws {
        _ = try await startServer { $0.consent = .timeout }
        let client = makeClient { $0.consentTimeout = .milliseconds(300) }
        do {
            _ = try await client.connect()
            XCTFail("expected consentTimedOut")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .consentTimedOut)
        }
    }

    func testAskOnStdinPromptsWithoutText() async throws {
        let mock = try await startServer { $0.consent = .askOnStdin }
        let client = makeClient(name: "Prompted App")
        let states = Recorder.start(client.stateUpdates())
        let connect = Task { try await client.connect() }
        try await states.wait("awaitingConsent") { $0.last == .awaitingConsent }
        let reply = await mock.handleConsoleCommand("y")
        XCTAssertEqual(reply, "granted 1 request(s)")
        _ = try await connect.value
        let prompt = await mock.log.first { $0.hasPrefix("[consent]") }
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains("Prompted App") == true)
        XCTAssertTrue(prompt?.contains("unverified:com.example.tests") == true)
    }

    // MARK: Token reuse and identity binding (C6, S18)

    func testTokenIsReusedOnReconnect() async throws {
        let mock = try await startServer()
        let store = InMemoryTokenStore()
        let client = makeClient(store: store)
        _ = try await client.connect()
        await client.disconnect()
        let states = Recorder.start(client.stateUpdates())
        _ = try await client.connect()
        let issued = await mock.issuedTokens
        XCTAssertEqual(issued.count, 1, "no second consent")
        let seen = try await states.wait("connected") { $0.contains { if case .connected = $0 { return true } else { return false } } }
        XCTAssertFalse(seen.contains(.awaitingConsent))
        let hellos = await mock.log.filter { $0.contains("hello client=com.example.tests") }
        XCTAssertTrue(hellos.last?.contains("token=present") == true)

        // A fresh client instance with the same store also skips consent.
        let second = makeClient(store: store)
        _ = try await second.connect()
        let issuedAfter = await mock.issuedTokens
        XCTAssertEqual(issuedAfter.count, 1)
    }

    func testTokenFromAnotherIdentityRePrompts() async throws {
        let mock = try await startServer()
        let store = InMemoryTokenStore()
        _ = try await makeClient(id: "com.example.first", store: store).connect()
        // Same store (same token), different client.id → different identity → re-prompt.
        let other = makeClient(id: "com.example.second", store: store)
        let states = Recorder.start(other.stateUpdates())
        _ = try await other.connect()
        let seen = try await states.wait("connected") { $0.contains { if case .connected = $0 { return true } else { return false } } }
        XCTAssertTrue(seen.contains(.awaitingConsent))
        let issued = await mock.issuedTokens
        XCTAssertEqual(issued.count, 2)
        let log = await mock.log
        XCTAssertTrue(log.contains { $0.contains("token bound to another identity") })
    }

    func testUnknownTokenRePrompts() async throws {
        let mock = try await startServer()
        let store = InMemoryTokenStore(initial: [server: "uc1_unknown"])
        let client = makeClient(store: store)
        _ = try await client.connect()
        let all = await store.all
        let issued = await mock.issuedTokens
        XCTAssertEqual(all[server], issued.first, "the fresh token replaced the unknown one")
    }

    func testPreSeededGrantSkipsConsent() async throws {
        _ = try await startServer { $0.knownTokens = ["uc1_seeded": "unverified:com.example.tests"] }
        let client = makeClient(store: InMemoryTokenStore(initial: [server: "uc1_seeded"]))
        let states = Recorder.start(client.stateUpdates())
        _ = try await client.connect()
        let seen = try await states.wait("connected") { $0.contains { if case .connected = $0 { return true } else { return false } } }
        XCTAssertFalse(seen.contains(.awaitingConsent))
    }

    // MARK: Revocation (S13, S17, C6)

    func testRevocationEndsSessionDeletesTokenAndHoldsTenMinutes() async throws {
        let mock = try await startServer()
        let store = InMemoryTokenStore()
        let client = makeClient(store: store)
        let session = try await client.read(ReadRequest(text: "Revoke me while I read."))
        let rec = record(session)
        try await rec.wait("loading") { $0.states.contains(.loading) }

        await mock.revoke(identity: "unverified:com.example.tests")
        let events = try await rec.waitForFinish()
        XCTAssertEqual(events.ended?.0, .revoked)

        let states = Recorder.start(client.stateUpdates())
        try await states.wait("disconnected") { $0.last == .disconnected }
        let last = await client.lastError
        XCTAssertEqual(last?.code, .unauthorized)
        XCTAssertEqual(last?.reason, "revoked")
        let all = await store.all
        XCTAssertTrue(all.isEmpty, "the revoked token is deleted")

        // No auto-retry for 10 minutes: connect() fails without contacting the server.
        let connectionsBefore = await mock.log.filter { $0.hasSuffix(" accepted") }.count
        do {
            _ = try await client.connect()
            XCTFail("expected unauthorized")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .unauthorized)
            XCTAssertEqual(e.reason, "revoked")
        }
        let connectionsAfter = await mock.log.filter { $0.hasSuffix(" accepted") }.count
        XCTAssertEqual(connectionsBefore, connectionsAfter)

        // forgetAuthorization() lifts the hold; the next connect re-prompts.
        try await client.forgetAuthorization()
        _ = try await client.connect()
        let issued = await mock.issuedTokens
        XCTAssertEqual(issued.count, 2)
    }

    func testRevokedTokenWithinTenMinutesIsRefusedWithoutPrompt() async throws {
        let mock = try await startServer()
        let first = try await rawHelloForToken(mock)
        await mock.revoke(identity: "unverified:com.example.raw")
        let r = try await raw(mock)
        try r.send(Self.hello(token: first))
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "unauthorized")
        XCTAssertEqual(e.string("reason"), "revoked")
        XCTAssertEqual(e.bool("fatal"), true)
        let closed = await r.readUntilClosedAsync(timeout: 3).closed
        XCTAssertTrue(closed)
    }

    // MARK: Prompt limits (S15)

    func testMoreThanThreeConsentRequestsPerMinuteAreRateLimited() async throws {
        let mock = try await startServer { $0.consent = .autoDeny(reason: "user") }
        for _ in 0..<3 {
            let r = try await raw(mock)
            try r.send(Self.hello())
            let d = try await r.expectAsync("consentDenied", timeout: 5)
            XCTAssertEqual(d.string("reason"), "user")
        }
        let r = try await raw(mock)
        try r.send(Self.hello())
        let d = try await r.expectAsync("consentDenied", timeout: 5)
        XCTAssertEqual(d.string("reason"), "rateLimited")
        let closed = await r.readUntilClosedAsync(timeout: 3).closed
        XCTAssertTrue(closed)
    }

    func testOnlyOnePendingRequestPerConnection() async throws {
        let mock = try await startServer { $0.consent = .timeout }
        let r = try await raw(mock)
        try r.send(Self.hello())
        _ = try await r.expectAsync("consentPending", timeout: 5)
        try r.send(Self.hello())
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "protocolError")
        let closed = await r.readUntilClosedAsync(timeout: 3).closed
        XCTAssertTrue(closed)
        let pending = await mock.pendingConsentCount
        XCTAssertEqual(pending, 0, "a closed connection's request leaves the queue")
    }

    func testCommandsBeforeWelcomeAreRefused() async throws {
        let mock = try await startServer { $0.consent = .timeout }
        let r = try await raw(mock)
        try r.send(Self.hello())
        _ = try await r.expectAsync("consentPending", timeout: 5)
        try r.send(["type": "ping", "id": 1])
        _ = try await r.expectAsync("pong", timeout: 5)
        try r.send(["type": "read", "id": 2, "sessionId": "x", "text": "Too early."])
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "unauthorized")
    }

    private func rawHelloForToken(_ mock: MockServer) async throws -> String {
        let r = try await raw(mock)
        try r.send(Self.hello())
        let g = try await r.expectAsync("consentGranted", timeout: 5)
        _ = try await r.expectAsync("welcome", timeout: 5)
        return try XCTUnwrap(g.string("token"))
    }
}
