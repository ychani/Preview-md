// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient
import UnivocalMock

private let text = "Woken up. Reading now."

// MARK: - Wake path (S47–S49, C21)

final class WakeTests: UnivocalTestCase {

    func testWakeURLConnectsAndTheRequestIsDeliveredAfterWelcome() async throws {
        let app = try makeTestApp()
        let wakes = WakeURLs()
        let mock = try await startHotkeyServer {
            $0.frontmost = MockFrontmost(pid: getpid(), bundleId: "com.example.fake", bundleURL: app)
            $0.wakeOpener = wakes.opener
        }
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        let press = Task { await mock.simulateHotkey() }

        let url = try await wakes.first()
        XCTAssertEqual(url.scheme, "fakeapp")
        XCTAssertEqual(url.host, "univocal-connect")
        XCTAssertEqual(url.path, "/read")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "v" }?.value, "1")
        let rid = try XCTUnwrap(UnivocalWakeURL.parse(url))
        let pending = await mock.pendingHotkeyRequestId
        XCTAssertEqual(pending, rid, "the request exists before the app is woken")
        let before = await mock.connectionCount
        XCTAssertEqual(before, 0)

        _ = try await client.connectForWake(requestId: rid)
        let req = try await requests.wait { !$0.isEmpty }[0]
        XCTAssertEqual(req.id, rid, "the woken connection answers the same request")
        let session = try await client.read(ReadRequest(text: text), answering: req)
        let outcome = await press.value
        XCTAssertEqual(outcome, .routed(sessionId: session.id, clientId: "com.example.tests", requestId: rid,
                                        accepted: false, viaWake: true))
        let log = await mock.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("woke fakeapp://univocal-connect/read?requestId=\(rid)&v=1"))
        XCTAssertFalse(log.contains("Reading now"))

        // Already connected: connectForWake returns the same connection and sends nothing.
        let again = try await client.connectForWake(requestId: "h-other")
        XCTAssertEqual(again.grantIdentity, "unverified:com.example.tests")
        let count = await mock.connectionCount
        XCTAssertEqual(count, 1)
    }

    func testOpenerFailureIsWakeFailed() async throws {
        let app = try makeTestApp()
        let wakes = WakeURLs(result: false)
        let mock = try await startHotkeyServer {
            $0.frontmost = MockFrontmost(pid: getpid(), bundleId: "com.example.fake", bundleURL: app)
            $0.wakeOpener = wakes.opener
        }
        let outcome = await mock.simulateHotkey()
        XCTAssertEqual(outcome, .fellBack(reason: "wakeFailed"))
    }

    func testNobodyConnectsIsWakeTimeout() async throws {
        let app = try makeTestApp()
        let wakes = WakeURLs()
        let mock = try await startHotkeyServer {
            $0.frontmost = MockFrontmost(pid: getpid(), bundleId: "com.example.fake", bundleURL: app)
            $0.wakeOpener = wakes.opener
            $0.wakeDeadline = .milliseconds(100)
        }
        let outcome = await mock.simulateHotkey()
        XCTAssertEqual(outcome, .fellBack(reason: "wakeTimeout"))
        let urls = await wakes.recorder.items
        XCTAssertEqual(urls.count, 1)
    }

    func testWakeBudgetIsSuspendedWhileConsentIsPending() async throws {
        let app = try makeTestApp()
        let wakes = WakeURLs()
        let mock = try await startHotkeyServer {
            $0.frontmost = MockFrontmost(pid: getpid(), bundleId: "com.example.fake", bundleURL: app)
            $0.wakeOpener = wakes.opener
            $0.wakeDeadline = .milliseconds(200)
            $0.consent = .askOnStdin
        }
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        let states = Recorder.start(client.stateUpdates())
        let press = Task { await mock.simulateHotkey() }
        let woke = try await wakes.first()
        let rid = try XCTUnwrap(UnivocalWakeURL.parse(woke))
        let connect = Task { try await client.connectForWake(requestId: rid) }
        try await states.wait("awaitingConsent") { $0.last == .awaitingConsent }
        // The subject of this test: the user takes longer than the wake budget to click Allow.
        try await Task.sleep(for: .milliseconds(400))
        let undecided = await mock.hotkeyOutcomes
        XCTAssertTrue(undecided.isEmpty, "the press is still pending: \(undecided)")
        await mock.grantPending()
        _ = try await connect.value
        let req = try await requests.wait { !$0.isEmpty }[0]
        XCTAssertEqual(req.id, rid)
        let session = try await client.read(ReadRequest(text: text), answering: req)
        let outcome = await press.value
        XCTAssertEqual(outcome, .routed(sessionId: session.id, clientId: "com.example.tests", requestId: rid,
                                        accepted: false, viaWake: true))
    }

    func testConsentDeniedAfterWakeFallsBack() async throws {
        let app = try makeTestApp()
        let wakes = WakeURLs()
        let mock = try await startHotkeyServer {
            $0.frontmost = MockFrontmost(pid: getpid(), bundleId: "com.example.fake", bundleURL: app)
            $0.wakeOpener = wakes.opener
            $0.consent = .askOnStdin
        }
        let client = makeTarget()
        let states = Recorder.start(client.stateUpdates())
        let press = Task { await mock.simulateHotkey() }
        let woke = try await wakes.first()
        let rid = try XCTUnwrap(UnivocalWakeURL.parse(woke))
        let connect = Task { try await client.connectForWake(requestId: rid) }
        try await states.wait("awaitingConsent") { $0.last == .awaitingConsent }
        await mock.denyPending()
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "consentDenied"))
        do {
            _ = try await connect.value
            XCTFail("expected consentDenied")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .consentDenied)
        }
    }

    func testWakeRequestIdFromAProcessThatDoesNotResolveIsAnOrdinaryHello() async throws {
        let app = try makeTestApp()
        let wakes = WakeURLs()
        // Frontmost is "launchd": this test process is not on its chain nor inside the bundle.
        let mock = try await startHotkeyServer {
            $0.frontmost = MockFrontmost(pid: 1, bundleId: "com.example.fake", bundleURL: app)
            $0.wakeOpener = wakes.opener
            $0.wakeDeadline = .milliseconds(300)
        }
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        let press = Task { await mock.simulateHotkey() }
        let woke = try await wakes.first()
        let rid = try XCTUnwrap(UnivocalWakeURL.parse(woke))
        let info = try await client.connectForWake(requestId: rid)
        XCTAssertEqual(info.grantIdentity, "unverified:com.example.tests", "an ordinary, successful hello")
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "wakeTimeout"))
        let items = await requests.items
        XCTAssertTrue(items.isEmpty)
        let log = await mock.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("does not resolve"))
    }

    func testUnknownWakeRequestIdIsAnOrdinaryHello() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()
        _ = try await client.connectForWake(requestId: "h-never-issued")
        let log = await mock.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("matches no pending wake"))
    }

    func testWokenConnectionWithoutHotkeyTargetFallsBack() async throws {
        let app = try makeTestApp()
        let wakes = WakeURLs()
        let mock = try await startHotkeyServer {
            $0.frontmost = MockFrontmost(pid: getpid(), bundleId: "com.example.fake", bundleURL: app)
            $0.wakeOpener = wakes.opener
        }
        let plain = makeClient()
        let press = Task { await mock.simulateHotkey() }
        let woke = try await wakes.first()
        let rid = try XCTUnwrap(UnivocalWakeURL.parse(woke))
        _ = try await plain.connectForWake(requestId: rid)
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "noTarget"))
    }

    func testMissingOrInvalidDeclarationIsNoDeclaration() async throws {
        let wakes = WakeURLs()
        let undeclared = try makeTestApp(name: "Plain", declare: false)
        let notTarget = try makeTestApp(name: "Off", hotkeyTarget: false)
        let mock = try await startHotkeyServer { $0.wakeOpener = wakes.opener }
        for app in [undeclared, notTarget] {
            await mock.setFrontmost(MockFrontmost(pid: getpid(), bundleId: "com.example.x", bundleURL: app))
            let outcome = await mock.simulateHotkey()
            XCTAssertEqual(outcome, .fellBack(reason: "noDeclaration"), app.lastPathComponent)
        }
        let urls = await wakes.recorder.items
        XCTAssertTrue(urls.isEmpty, "nothing is opened without a valid declaration")
    }
}

// MARK: - Connect at launch (S50, C22)

final class ConnectAtLaunchTests: UnivocalTestCase {
    private let serverId = "com.univocal.app"
    private let seeded = "uc1_seededseededseededseededseededseededseede"

    func testNoTokenMeansNoConnection() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()
        let info = try await client.connectIfAuthorized()
        XCTAssertNil(info)
        let count = await mock.connectionCount
        XCTAssertEqual(count, 0)
        let log = await mock.log.joined(separator: "\n")
        XCTAssertFalse(log.contains("accepted"), "no connection was even opened")
    }

    func testValidTokenConnectsQuietly() async throws {
        let mock = try await startHotkeyServer { [seeded] in $0.knownTokens = [seeded: "unverified:com.example.tests"] }
        let store = InMemoryTokenStore(initial: [serverId: seeded])
        let client = makeTarget(store: store)
        let info = try await client.connectIfAuthorized()
        XCTAssertEqual(info?.grantIdentity, "unverified:com.example.tests")
        let again = try await client.connectIfAuthorized()
        XCTAssertEqual(again, info, "idempotent when connected")
        let log = await mock.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("token=present"))
        XCTAssertTrue(log.contains(" quiet"))
        // A quiet connection is ordinary: it receives readRequests.
        let requests = Recorder.start(client.readRequests())
        let press = Task { await mock.simulateHotkey() }
        let req = try await requests.wait { !$0.isEmpty }[0]
        try await client.decline(req, reason: .busy)
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "declined:busy"))
    }

    func testUnknownTokenIsDeniedQuietlyAndDiscarded() async throws {
        let mock = try await startHotkeyServer { $0.consent = .askOnStdin }   // would print a prompt if asked
        let store = InMemoryTokenStore(initial: [serverId: "uc1_unknownunknownunknownunknownunknownunknow"])
        let client = makeTarget(store: store)
        let info = try await client.connectIfAuthorized()
        XCTAssertNil(info)
        let all = await store.all
        XCTAssertTrue(all.isEmpty, "the refused token is deleted")
        let pending = await mock.pendingConsentCount
        XCTAssertEqual(pending, 0)
        let log = await mock.log.joined(separator: "\n")
        XCTAssertFalse(log.contains("[consent]"), "no prompt was shown")
        XCTAssertTrue(log.contains("quiet hello needs consent"))
        let last = await client.lastError
        XCTAssertNil(last, "a refused quiet hello is not an error")
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
    }

    func testRawQuietHelloGetsConsentDeniedQuietThenClose() async throws {
        let mock = try await startHotkeyServer()
        let r = try await raw(mock)
        var h = Self.hello()
        h["quiet"] = true
        try r.send(h)
        let m = try await r.nextAsync(timeout: 5)
        XCTAssertEqual(m?.messageType, "consentDenied")
        XCTAssertEqual(m?.string("reason"), "quiet")
        let closed = await r.readUntilClosedAsync(timeout: 3)
        XCTAssertTrue(closed.closed)
    }

    func testServerNotRunningAndNeverLaunches() async throws {
        let launched = LaunchFlag()
        let store = InMemoryTokenStore(initial: [serverId: seeded])
        let client = makeTarget(store: store) { c in
            c.appLocator = { _ in URL(fileURLWithPath: "/Applications/Univocal.app") }   // "installed"
            c.launcher = { _, _ in
                await launched.set()
                throw UnivocalError(code: .launchTimedOut, message: "tests never launch apps")
            }
        }
        let info = try await client.connectIfAuthorized()
        XCTAssertNil(info)
        let didLaunch = await launched.value
        XCTAssertFalse(didLaunch)
        let all = await store.all
        XCTAssertEqual(all.count, 1, "the token is kept: nothing refused it")
    }

    func testConnectAfterAQuietRefusalStillPrompts() async throws {
        _ = try await startHotkeyServer()   // auto-grant
        let store = InMemoryTokenStore(initial: [serverId: "uc1_unknownunknownunknownunknownunknownunknow"])
        let client = makeTarget(store: store)
        let quiet = try await client.connectIfAuthorized()
        XCTAssertNil(quiet)
        let info = try await client.connect()
        XCTAssertEqual(info.grantIdentity, "unverified:com.example.tests")
        let all = await store.all
        XCTAssertEqual(all.count, 1, "the user-initiated connect stored a fresh token")
    }
}

actor LaunchFlag {
    private(set) var value = false
    func set() { value = true }
}

// MARK: - Server appearances (C22)

final class ServerAppearanceTests: UnivocalTestCase {

    private func config(_ directory: URL) -> UnivocalConfiguration {
        var c = UnivocalConfiguration(client: .init(id: "com.example.tests", name: "Tests", version: "1"), environment: [:])
        c.connectDirectory = directory
        c.tokenStore = InMemoryTokenStore()
        return c
    }

    func testYieldsTheRunningServerFirst() async throws {
        let mock = try await startServer()
        let appearances = Recorder.start(UnivocalLocator.serverAppearances(configuration: config(dir)))
        let items = try await appearances.wait { !$0.isEmpty }
        let socket = await mock.socketPath
        XCTAssertEqual(items[0].socketPath, socket)
        XCTAssertEqual(items[0].pid, getpid())
    }

    func testYieldsWhenTheServerStartsAndRestarts() async throws {
        let appearances = Recorder.start(UnivocalLocator.serverAppearances(configuration: config(dir)))
        let first = try await startServer()
        let items = try await appearances.wait("first appearance") { !$0.isEmpty }
        XCTAssertEqual(items[0].serverVersion, "1.0.0")
        await first.stop()
        _ = try await startServer { $0.serverVersion = "2.0.0" }
        let again = try await appearances.wait("second appearance") { $0.count >= 2 }
        XCTAssertEqual(again[1].serverVersion, "2.0.0")
    }

    func testWatchesForADirectoryThatDoesNotExistYet() async throws {
        let later = dir.appendingPathComponent("later/Connect", isDirectory: true)
        let appearances = Recorder.start(UnivocalLocator.serverAppearances(configuration: config(later)))
        _ = try await startServer(in: later)
        let items = try await appearances.wait("appearance in a new directory") { !$0.isEmpty }
        XCTAssertEqual(items[0].serverName, "Univocal Mock")
    }
}
