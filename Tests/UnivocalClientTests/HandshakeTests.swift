// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient
import UnivocalMock

final class HandshakeTests: UnivocalTestCase {

    // MARK: SDK happy path (S12, S33, C2, C5)

    func testConnectHappyPathReportsServerInfoAndStates() async throws {
        let server = try await startServer()
        let client = makeClient()
        let states = Recorder.start(client.stateUpdates())
        let info = try await client.connect(launchIfNeeded: false)

        XCTAssertEqual(info.name, "Univocal Mock")
        XCTAssertEqual(info.bundleId, "com.univocal.app")
        XCTAssertEqual(info.protocolVersion, 1)
        XCTAssertEqual(info.transport, .unixSocket)
        XCTAssertEqual(info.grantIdentity, "unverified:com.example.tests")
        XCTAssertGreaterThanOrEqual(info.maxFrameBytes, 1_048_576)
        XCTAssertEqual(info.rateRange, 0.25...4.0)
        XCTAssertTrue(info.capabilities.isSuperset(of: ["word-events", "sentence-events", "seek", "rate", "chunking", "voices"]))

        let seen = try await states.wait("connected") { $0.contains { if case .connected = $0 { return true } else { return false } } }
        XCTAssertEqual(seen.first, .disconnected, "a new stream yields the current state first")
        XCTAssertTrue(seen.contains(.connecting))
        XCTAssertTrue(seen.contains(.awaitingConsent), "first contact goes through consent")
        let clientState = await client.state
        XCTAssertEqual(clientState, .connected(info))

        // Idempotent, and the mock saw a well-formed hello (C2: it validates client.id etc.).
        let again = try await client.connect()
        XCTAssertEqual(again, info)
        let log = await server.log
        XCTAssertEqual(log.filter { $0.contains("hello client=com.example.tests") }.count, 1)
        XCTAssertTrue(log.contains { $0.contains("caps=sentence-events,word-events") })
    }

    func testEachStateStreamIsIndependent() async throws {
        _ = try await startServer()
        let client = makeClient()
        let a = Recorder.start(client.stateUpdates())
        let b = Recorder.start(client.stateUpdates())
        _ = try await client.connect()
        for r in [a, b] {
            try await r.wait("connected") { $0.contains { if case .connected = $0 { return true } else { return false } } }
        }
        await client.disconnect()
        try await a.wait("disconnected again") { $0.last == .disconnected }
    }

    func testConcurrentConnectsShareOneHandshake() async throws {
        let server = try await startServer()
        let client = makeClient()
        async let one = client.connect()
        async let two = client.connect()
        let (x, y) = try await (one, two)
        XCTAssertEqual(x, y)
        let hellos = await server.log.filter { $0.contains(" hello ") }
        XCTAssertEqual(hellos.count, 1)
    }

    func testPingRoundTrip() async throws {
        _ = try await startServer()
        let client = makeClient()
        let rtt = try await client.ping()
        XCTAssertLessThan(rtt, .seconds(2))
    }

    // MARK: Raw protocol rules (S4–S7, S10, S11, S32)

    func testFirstMessageMustBeHello() async throws {
        let server = try await startServer()
        let r = try await raw(server)
        try r.send(["type": "ping", "id": 1])
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "protocolError")
        XCTAssertEqual(e.bool("fatal"), true)
        XCTAssertNotNil(e.string("message"))
        let closed = await r.readUntilClosedAsync(timeout: 3).closed
        XCTAssertTrue(closed, "fatal errors are followed by close")
    }

    func testWrongProtocolIsFatal() async throws {
        let server = try await startServer()
        let r = try await raw(server)
        try r.send(Self.hello(proto: "not-univocal"))
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "protocolError")
        let closed = await r.readUntilClosedAsync(timeout: 3).closed
        XCTAssertTrue(closed)
    }

    func testUnsupportedVersionListsServerVersions() async throws {
        let server = try await startServer()
        let r = try await raw(server)
        try r.send(Self.hello(versions: [2, 3]))
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "unsupportedVersion")
        XCTAssertEqual(e.bool("fatal"), true)
        XCTAssertEqual(e.array("versions"), [1])
        let closed = await r.readUntilClosedAsync(timeout: 3).closed
        XCTAssertTrue(closed)
    }

    func testInvalidClientIdIsRefused() async throws {
        let server = try await startServer()
        let r = try await raw(server)
        try r.send(Self.hello(id: "not valid!"))
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "invalidArgument")
        XCTAssertEqual(e.string("field"), "client.id")
    }

    func testCRLFFramesAreAccepted() async throws {
        let server = try await startServer()
        let r = try await rawWelcomed(server)
        try r.sendRaw("{\"type\":\"ping\",\"id\":5}\r\n")
        let p = try await r.expectAsync("pong", timeout: 5)
        XCTAssertEqual(p["id"], 5)
    }

    func testMalformedJSONIsFatal() async throws {
        let server = try await startServer()
        let r = try await rawWelcomed(server)
        try r.sendRaw("{\"type\":\"ping\", nope}\n")
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "protocolError")
        XCTAssertEqual(e.bool("fatal"), true)
        let closed = await r.readUntilClosedAsync(timeout: 3).closed
        XCTAssertTrue(closed)
    }

    func testOneMebibyteFrameAcceptedAndOversizeFrameIsFatal() async throws {
        let server = try await startServer()
        let r = try await rawWelcomed(server)
        let shell = try UnivocalWire.encode(["type": "ping", "id": 1, "pad": ""])
        let big = try UnivocalWire.frame(["type": "ping", "id": 1, "pad": .string(String(repeating: "x", count: 1_048_576 - shell.count - 1))])
        XCTAssertEqual(big.count, 1_048_576)
        try r.sendRaw(big)
        let pong = try await r.expectAsync("pong", timeout: 5)
        XCTAssertEqual(pong["id"], 1)

        let r2 = try await rawWelcomed(server, id: "com.example.raw2")
        try? r2.sendRaw(Data(repeating: 0x61, count: 1_048_576 + 10))
        let e = try await r2.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "protocolError")
        XCTAssertEqual(e.bool("fatal"), true)
        let closed = await r2.readUntilClosedAsync(timeout: 3).closed
        XCTAssertTrue(closed)
    }

    func testUnknownTypesAndFields() async throws {
        let server = try await startServer()
        let r = try await rawWelcomed(server)
        try r.send(["type": "x-future", "id": "abc"])
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "unknownType")
        XCTAssertEqual(e.bool("fatal"), false)
        XCTAssertEqual(e["id"], "abc")
        try r.send(["type": "x-future"])                       // no id → ignored
        try r.send(["type": "ping", "id": 2, "x-extra": [1, 2]])  // unknown field ignored
        let next = try await r.nextAsync(timeout: 5)
        XCTAssertEqual(next?.messageType, "pong")
        XCTAssertEqual(next?["id"], 2)
    }

    func testPingEchoesStringAndIntegerIds() async throws {
        let server = try await startServer()
        let r = try await rawWelcomed(server)
        try r.send(["type": "ping", "id": "s-1"])
        let a = try await r.expectAsync("pong", timeout: 5)
        XCTAssertEqual(a["id"], "s-1")
        try r.send(["type": "ping", "id": 77])
        let b = try await r.expectAsync("pong", timeout: 5)
        XCTAssertEqual(b["id"], 77)
    }

    /// C3: the SDK ignores unknown message types and fields mid-session.
    func testClientIgnoresInjectedNoise() async throws {
        let server = try await startServer { $0.injectUnknownMessages = true }
        let client = makeClient()
        let session = try await client.read(ReadRequest(text: "One two three four five six."))
        let rec = record(session)
        await server.advance(words: 10)
        let events = try await rec.waitForFinish()
        XCTAssertEqual(events.words.count, 6)
        XCTAssertEqual(events.ended?.0, .finished)
    }

    // MARK: Discovery and launch (C1, C12, A.4.1)

    func testNotInstalledAndNotRunning() async throws {
        let client = makeClient()
        do {
            _ = try await client.connect()
            XCTFail("expected notInstalled")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .notInstalled)
        }
        let installed = makeClient { $0.appLocator = { _ in URL(fileURLWithPath: "/Applications/Univocal.app") } }
        do {
            _ = try await installed.connect(launchIfNeeded: false)
            XCTFail("expected notRunning")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .notRunning)
        }
        let last = await installed.lastError
        XCTAssertEqual(last?.code, .notRunning)
    }

    func testLaunchTimesOutWhenServerNeverAppears() async throws {
        let launches = Counter()
        let client = makeClient {
            $0.appLocator = { _ in URL(fileURLWithPath: "/Applications/Univocal.app") }
            $0.launcher = { _, bundleId in
                XCTAssertEqual(bundleId, "com.univocal.app")
                await launches.increment()
            }
            $0.launchTimeout = .milliseconds(600)
        }
        let states = Recorder.start(client.stateUpdates())
        do {
            _ = try await client.connect()
            XCTFail("expected launchTimedOut")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .launchTimedOut)
        }
        let n = await launches.value
        XCTAssertEqual(n, 1)
        try await states.wait("launching") { $0.contains(.launching) }
    }

    func testLaunchOnDemandConnectsOnceTheServerAppears() async throws {
        let dir = self.dir!
        let holder = ServerHolder()
        let client = makeClient {
            $0.appLocator = { _ in URL(fileURLWithPath: "/Applications/Univocal.app") }
            $0.launcher = { _, _ in
                // Simulate an app that brings its listener up a little later.
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    var b = MockBehaviour()
                    b.loadingDelay = .zero
                    let s = MockServer(directory: dir, behaviour: b)
                    try? await s.start()
                    await holder.set(s)
                }
            }
        }
        let info = try await client.connect()
        XCTAssertEqual(info.protocolVersion, 1)
        await client.disconnect()
        await holder.server?.stop()
    }

    // MARK: Transport loss (A.4.7)

    func testServerGoingAwayEndsSessionWithError() async throws {
        let server = try await startServer()
        let client = makeClient()
        let session = try await client.read(ReadRequest(text: "This will be interrupted."))
        let rec = record(session)
        try await rec.wait("loading") { $0.states.contains(.loading) }
        await server.stop()
        let events = try await rec.waitForFinish()
        XCTAssertEqual(events.errors.last?.code, .disconnected)
        XCTAssertEqual(events.ended?.0, .error)
        XCTAssertTrue(session.isEnded)
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
        let last = await client.lastError
        XCTAssertNotNil(last)
        do {
            try await session.pause()
            XCTFail("controls on an ended session must throw")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .sessionEnded)
        }
    }

    func testClientDisconnectEndsSessionLocally() async throws {
        _ = try await startServer()
        let client = makeClient()
        let session = try await client.read(ReadRequest(text: "Disconnect me."))
        let rec = record(session)
        await client.disconnect()
        let events = try await rec.waitForFinish()
        XCTAssertEqual(events.ended?.0, .stopped)
        let last = await client.lastError
        XCTAssertNil(last, "a user disconnect is not an error")
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

actor ServerHolder {
    private(set) var server: MockServer?
    func set(_ s: MockServer) { server = s }
}
