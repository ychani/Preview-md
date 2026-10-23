// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient
import UnivocalMock

// MARK: - Helpers

extension UnivocalTestCase {
    /// The test process as the frontmost app: SDK connections from this process resolve to it.
    var me: MockFrontmost { MockFrontmost(pid: getpid(), bundleId: "com.example.tests") }

    /// Generous deadlines (only tests about timeouts shorten them); a wake opener that never
    /// opens anything real; this process frontmost.
    func startHotkeyServer(_ configure: (inout MockBehaviour) -> Void = { _ in }) async throws -> MockServer {
        let front = me
        return try await startServer { b in
            b.answerDeadline = .seconds(2)
            b.acceptedDeadline = .seconds(5)
            b.wakeDeadline = .seconds(5)
            b.wakeOpener = { _ in false }
            b.frontmost = front
            configure(&b)
        }
    }

    func makeTarget(id: String = "com.example.tests", store: InMemoryTokenStore? = nil,
                    _ configure: (inout UnivocalConfiguration) -> Void = { _ in }) -> UnivocalClient {
        makeClient(id: id, store: store) { c in
            c.hotkeyTarget = true
            configure(&c)
        }
    }

    /// `<dir>/<name>.app/Contents/Info.plist` with an Appendix B declaration.
    func makeTestApp(name: String = "Fake", scheme: String = "fakeapp", hotkeyTarget: Bool = true,
                     declare: Bool = true, register: Bool = true) throws -> URL {
        let app = dir.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.example.\(name.lowercased())", "CFBundleName": name]
        if declare {
            info[UnivocalAppDeclaration.infoPlistKey] = ["Versions": [1], "HotkeyTarget": hotkeyTarget, "WakeURLScheme": scheme]
        }
        if register {
            info["CFBundleURLTypes"] = [["CFBundleURLName": "com.example.\(name.lowercased()).url",
                                         "CFBundleURLSchemes": [scheme], "LSHandlerRank": "Owner"]]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}

/// Records wake URLs handed to the mock's injected opener.
final class WakeURLs: @unchecked Sendable {
    let recorder: Recorder<URL>
    private let continuation: AsyncStream<URL>.Continuation
    let result: Bool

    init(result: Bool = true) {
        let (stream, cont) = AsyncStream<URL>.makeStream()
        continuation = cont
        recorder = Recorder.start(stream)
        self.result = result
    }

    var opener: @Sendable (URL) -> Bool {
        { [continuation, result] url in
            continuation.yield(url)
            return result
        }
    }

    func first() async throws -> URL {
        try await recorder.wait("a wake URL") { !$0.isEmpty }[0]
    }
}

private let docText = "Hello there. General Kenobi! You are a bold one."

// MARK: - Routing (S37, S40–S46, C15–C20, C23)

final class HotkeyRoutingTests: UnivocalTestCase {

    func testReadAnsweringRoutesWithoutAccept() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        let info = try await client.connect()
        XCTAssertTrue(info.capabilities.contains("hotkey-routing"))

        let press = Task { await mock.simulateHotkey() }
        let req = try await requests.wait("a readRequest") { !$0.isEmpty }[0]
        XCTAssertEqual(req.trigger, .hotkey)
        XCTAssertEqual(req.prefer, .selection)
        XCTAssertEqual(req.answerMs, 2000)
        XCTAssertEqual(req.acceptedMs, 5000)
        XCTAssertEqual(req.answerDeadline, req.receivedAt.advanced(by: .seconds(2)))
        let pending = await mock.pendingHotkeyRequestId
        XCTAssertEqual(pending, req.id)

        var r = ReadRequest(text: docText)
        r.startOffset = 13
        r.preempt = false   // ignored: a hotkey read always takes over
        r.title = "Secret Title.md"
        let session = try await client.read(r, answering: req)
        let outcome = await press.value
        XCTAssertEqual(outcome, .routed(sessionId: session.id, clientId: "com.example.tests", requestId: req.id,
                                        accepted: false, viaWake: false))

        let events = record(session)
        try await events.wait("playing") { $0.states.contains(.playing) }
        await mock.advance(words: 1)
        let got = try await events.wait("a word") { !$0.words.isEmpty }
        XCTAssertEqual(substring(docText, got.words[0]), "General", "the session starts at the sentence containing startOffset")
        let active = await mock.activeSessionId
        XCTAssertEqual(active, session.id)
        let fallbacks = await mock.hotkeyFallbackCount
        XCTAssertEqual(fallbacks, 0)

        // S53: hotkey routing logs ids, pids, reasons and timings — never text or titles.
        let log = await mock.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("hotkey #1 outcome: routed"))
        XCTAssertTrue(log.contains("pid=\(getpid())"))
        for fragment in ["Kenobi", "Hello there", "bold one", "Secret Title"] {
            XCTAssertFalse(log.contains(fragment), "log leaks \(fragment)")
        }
        XCTAssertTrue(log.contains("caps=hotkey-target,sentence-events,word-events"), "the SDK announces hotkey-target itself")
    }

    func testAcceptExtendsTheDeadlineToAcceptedMs() async throws {
        let mock = try await startHotkeyServer {
            $0.answerDeadline = .milliseconds(100)
            $0.acceptedDeadline = .seconds(5)
        }
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        _ = try await client.connect()
        let press = Task { await mock.simulateHotkey(prefer: .document) }
        let req = try await requests.wait { !$0.isEmpty }[0]
        XCTAssertEqual(req.prefer, .document)
        try await client.accept(req)
        // C17: readAccepted goes out at once.
        XCTAssertLessThan(ContinuousClock.now - req.receivedAt, .milliseconds(50))
        try await client.accept(req)   // idempotent
        // The subject of this test: answer only after the answer deadline has passed.
        try await Task.sleep(until: req.answerDeadline.advanced(by: .milliseconds(150)), clock: .continuous)
        let session = try await client.read(ReadRequest(text: docText), answering: req)
        let outcome = await press.value
        XCTAssertEqual(outcome, .routed(sessionId: session.id, clientId: "com.example.tests", requestId: req.id,
                                        accepted: true, viaWake: false))
    }

    func testAcceptedTimeoutFallsBackAndTheLateReadIsRejected() async throws {
        let mock = try await startHotkeyServer {
            $0.answerDeadline = .milliseconds(300)
            $0.acceptedDeadline = .milliseconds(400)
        }
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        _ = try await client.connect()
        let press = Task { await mock.simulateHotkey() }
        let req = try await requests.wait { !$0.isEmpty }[0]
        try await client.accept(req)
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "acceptedTimeout"))
        do {
            _ = try await client.read(ReadRequest(text: docText), answering: req)
            XCTFail("a late read must be rejected")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .unknownRequest)   // C20: "too late", nothing started
        }
        let active = await mock.activeSessionId
        XCTAssertNil(active)
        let fallbacks = await mock.hotkeyFallbackCount
        XCTAssertEqual(fallbacks, 1)
        let state = await client.state
        if case .connected = state {} else { XCTFail("unknownRequest is not fatal; got \(state)") }
    }

    func testAnswerTimeoutWhenTheClientSaysNothing() async throws {
        let mock = try await startHotkeyServer { $0.answerDeadline = .milliseconds(50) }
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())   // consumes, never answers
        _ = try await client.connect()
        let outcome = await mock.simulateHotkey()
        XCTAssertEqual(outcome, .fellBack(reason: "answerTimeout"))
        let items = await requests.items
        XCTAssertEqual(items.count, 1)
    }

    func testDeclineFallsBackAndASecondAnswerThrows() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        _ = try await client.connect()
        let press = Task { await mock.simulateHotkey() }
        let req = try await requests.wait { !$0.isEmpty }[0]
        try await client.decline(req, reason: .noContent, detail: "editView")
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "declined:noContent"))
        for attempt in 0..<3 {
            do {
                switch attempt {
                case 0: try await client.decline(req, reason: .busy)
                case 1: try await client.accept(req)
                default: _ = try await client.read(ReadRequest(text: docText), answering: req)
                }
                XCTFail("attempt \(attempt) must throw requestAnswered")
            } catch let e as UnivocalError {
                XCTAssertEqual(e.code, .requestAnswered)
            }
        }
        let log = await mock.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("reason=noContent detail=editView"))
    }

    func testNotFocusedCascadesToTheNextConnectionOfTheSameApp() async throws {
        let mock = try await startHotkeyServer()
        let first = makeTarget()
        let second = makeTarget()
        let r1 = Recorder.start(first.readRequests())
        let r2 = Recorder.start(second.readRequests())
        _ = try await first.connect()
        _ = try await second.connect()
        _ = try await first.ping()   // most recent inbound message → asked first
        let press = Task { await mock.simulateHotkey() }
        let req1 = try await r1.wait { !$0.isEmpty }[0]
        let early = await r2.items
        XCTAssertTrue(early.isEmpty, "only one connection is asked at a time")
        try await first.decline(req1, reason: .notFocused)
        let req2 = try await r2.wait { !$0.isEmpty }[0]
        XCTAssertNotEqual(req2.id, req1.id, "each candidate gets a fresh requestId")
        let session = try await second.read(ReadRequest(text: docText), answering: req2)
        let outcome = await press.value
        XCTAssertEqual(outcome, .routed(sessionId: session.id, clientId: "com.example.tests", requestId: req2.id,
                                        accepted: false, viaWake: false))
    }

    func testCandidateOrderIsMostRecentInboundFirst() async throws {
        let mock = try await startHotkeyServer()
        let first = makeTarget()
        let second = makeTarget()
        let r1 = Recorder.start(first.readRequests())
        let r2 = Recorder.start(second.readRequests())
        _ = try await second.connect()
        _ = try await first.connect()     // newest connection…
        _ = try await second.ping()       // …but the second spoke last
        let press = Task { await mock.simulateHotkey() }
        let req = try await r2.wait { !$0.isEmpty }[0]
        let none = await r1.items
        XCTAssertTrue(none.isEmpty)
        try await second.decline(req, reason: .notFocused)
        let req1 = try await r1.wait { !$0.isEmpty }[0]
        try await first.decline(req1, reason: .notFocused)
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "declined:notFocused"), "all notFocused candidates exhausted")
    }

    func testToggleOnRepeatPausesAndResumesWithoutARequest() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        _ = try await client.connect()
        let press = Task { await mock.simulateHotkey() }
        let req = try await requests.wait { !$0.isEmpty }[0]
        let session = try await client.read(ReadRequest(text: docText), answering: req)
        _ = await press.value
        let events = record(session)
        try await events.wait("playing") { $0.states.last == .playing }

        let o1 = await mock.simulateHotkey()
        XCTAssertEqual(o1, .toggled(sessionId: session.id, paused: true))
        try await events.wait("paused") { $0.states.last == .paused }   // C23: applied like any state change
        let o2 = await mock.simulateHotkey()
        XCTAssertEqual(o2, .toggled(sessionId: session.id, paused: false))
        try await events.wait("playing again") { $0.states.last == .playing }
        let count = await requests.items.count
        XCTAssertEqual(count, 1, "a toggle sends no readRequest")
    }

    func testPressInAnotherAppPreemptsThenFallsBack() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        _ = try await client.connect()
        let press = Task { await mock.simulateHotkey() }
        let req = try await requests.wait { !$0.isEmpty }[0]
        let session = try await client.read(ReadRequest(text: docText), answering: req)
        _ = await press.value
        let events = record(session)

        await mock.setFrontmost(MockFrontmost(pid: 1, bundleId: "com.example.other"))
        let outcome = await mock.simulateHotkey()
        XCTAssertEqual(outcome, .fellBack(reason: "noTarget"))
        let got = try await events.waitForFinish()
        XCTAssertEqual(got.ended?.0, .preempted)
        XCTAssertEqual(got.ended?.1, "Univocal")
    }

    func testNewerPressSupersedesWithoutASecondFallback() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        _ = try await client.connect()
        let p1 = Task { await mock.simulateHotkey() }
        let old = try await requests.wait { !$0.isEmpty }[0]
        let p2 = Task { await mock.simulateHotkey() }
        let o1 = await p1.value
        XCTAssertEqual(o1, .fellBack(reason: "superseded"))
        let new = try await requests.wait { $0.count >= 2 }[1]
        XCTAssertNotEqual(new.id, old.id)
        let session = try await client.read(ReadRequest(text: docText), answering: new)
        let o2 = await p2.value
        XCTAssertEqual(o2, .routed(sessionId: session.id, clientId: "com.example.tests", requestId: new.id,
                                   accepted: false, viaWake: false))
        do {
            _ = try await client.read(ReadRequest(text: "Too late."), answering: old)
            XCTFail("the superseded request is dead")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .unknownRequest)
        }
        let active = await mock.activeSessionId
        XCTAssertEqual(active, session.id)
        let fallbacks = await mock.hotkeyFallbackCount
        XCTAssertEqual(fallbacks, 0, "superseded presses never run the fallback")
        let outcomes = await mock.hotkeyOutcomes
        XCTAssertEqual(outcomes.count, 2)
    }

    func testServerFrontmostIsSelfHandled() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        _ = try await client.connect()
        await mock.setFrontmost(MockFrontmost(pid: getpid(), bundleId: "com.univocal.mock"))
        let outcome = await mock.simulateHotkey()
        XCTAssertEqual(outcome, .selfHandled)
        let items = await requests.items
        XCTAssertTrue(items.isEmpty)
        let fallbacks = await mock.hotkeyFallbackCount
        XCTAssertEqual(fallbacks, 0)
    }

    // MARK: Capability gating (S37, C15)

    func testClientWithoutHotkeyTargetIsNeverAsked() async throws {
        let mock = try await startHotkeyServer()
        let plain = makeClient()
        let requests = Recorder.start(plain.readRequests())
        _ = try await plain.connect()
        let outcome = await mock.simulateHotkey()
        XCTAssertEqual(outcome, .fellBack(reason: "noTarget"))
        let items = await requests.items
        XCTAssertTrue(items.isEmpty)
        let log = await mock.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("caps=sentence-events,word-events"))
    }

    func testOnlyTheHotkeyTargetConnectionIsAsked() async throws {
        let mock = try await startHotkeyServer()
        let plain = makeClient(id: "com.example.plain")
        let target = makeTarget()
        let rp = Recorder.start(plain.readRequests())
        let rt = Recorder.start(target.readRequests())
        _ = try await target.connect()
        _ = try await plain.connect()   // the plain one spoke last but is not a candidate
        let press = Task { await mock.simulateHotkey() }
        let req = try await rt.wait { !$0.isEmpty }[0]
        try await target.decline(req, reason: .userDisabled)
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "declined:userDisabled"))
        let none = await rp.items
        XCTAssertTrue(none.isEmpty)
    }

    func testDraft1ServerNeitherAnnouncesNorRoutes() async throws {
        let mock = try await startHotkeyServer { $0.hotkeyRouting = false }
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        let info = try await client.connect()
        XCTAssertFalse(info.capabilities.contains("hotkey-routing"))
        let outcome = await mock.simulateHotkey()
        XCTAssertEqual(outcome, .fellBack(reason: "noTarget"))
        let items = await requests.items
        XCTAssertTrue(items.isEmpty)

        // A Draft 1 server treats readAccepted/readDecline as unknown types.
        let r = try await rawWelcomed(mock, capabilities: ["word-events", "hotkey-target"])
        try r.send(["type": "readAccepted", "requestId": "x"])
        try r.send(["type": "readDecline", "requestId": "x", "reason": "other", "id": 4])
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "unknownType")
        XCTAssertEqual(e["id"], .int(4))
    }

    func testNoConsumerDeclinesAtOnce() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()   // hotkeyTarget, but nobody calls readRequests()
        _ = try await client.connect()
        let outcome = await mock.simulateHotkey()
        XCTAssertEqual(outcome, .fellBack(reason: "declined:other"))
        let log = await mock.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("detail=noConsumer"))
    }

    // MARK: Raw wire (S44, S45, S46)

    func testReadWithAnUnknownRequestIdIsNotStarted() async throws {
        let mock = try await startHotkeyServer()
        let r = try await rawWelcomed(mock, capabilities: ["word-events", "sentence-events", "hotkey-target"])
        try r.send(["type": "readAccepted", "requestId": "nope"])           // stale: ignored silently
        try r.send(["type": "readDecline", "requestId": "nope", "reason": "busy"])
        try r.send(["type": "read", "id": 5, "sessionId": "S-x", "text": "Never started.", "requestId": "nope"])
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "unknownRequest")
        XCTAssertEqual(e["id"], .int(5))
        XCTAssertEqual(e.bool("fatal"), false)
        try r.send(["type": "ping", "id": 6])
        let p = try await r.nextAsync(timeout: 5)
        XCTAssertEqual(p?.messageType, "pong", "nothing else was sent (no ok, no state, no error for the stale messages)")
        let active = await mock.activeSessionId
        XCTAssertNil(active)
    }

    func testInvalidAnsweringReadFallsBackAsReadRejected() async throws {
        let mock = try await startHotkeyServer()
        let r = try await rawWelcomed(mock, capabilities: ["word-events", "hotkey-target"])
        let press = Task { await mock.simulateHotkey() }
        let req = try await r.expectAsync("readRequest", timeout: 5)
        let rid = try XCTUnwrap(req.string("requestId"))
        XCTAssertEqual(req.string("trigger"), "hotkey")
        try r.send(["type": "read", "id": 1, "sessionId": "S-empty", "text": "", "requestId": .string(rid)])
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "invalidArgument")
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "readRejected:invalidArgument"))
    }

    func testConnectionClosingMidRequestFallsBack() async throws {
        let mock = try await startHotkeyServer()
        let r = try await rawWelcomed(mock, capabilities: ["word-events", "hotkey-target"])
        let press = Task { await mock.simulateHotkey() }
        _ = try await r.expectAsync("readRequest", timeout: 5)
        r.close()
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "disconnected"))
    }

    func testRequestsDieWithTheirConnection() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        _ = try await client.connect()
        let press = Task { await mock.simulateHotkey() }
        let req = try await requests.wait { !$0.isEmpty }[0]
        await client.disconnect()
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "disconnected"))
        _ = try await client.connect()
        do {
            try await client.accept(req)
            XCTFail("a request from a closed connection cannot be answered")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .disconnected)
        }
        // A request built by a test double belongs to no connection.
        do {
            _ = try await client.read(ReadRequest(text: docText), answering: UnivocalReadRequest(id: "fake"))
            XCTFail("expected disconnected")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .disconnected)
        }
    }

    func testLocalValidationFailureLeavesTheRequestAnswerable() async throws {
        let mock = try await startHotkeyServer()
        let client = makeTarget()
        let requests = Recorder.start(client.readRequests())
        _ = try await client.connect()
        let press = Task { await mock.simulateHotkey() }
        let req = try await requests.wait { !$0.isEmpty }[0]
        do {
            _ = try await client.read(ReadRequest(text: ""), answering: req)
            XCTFail("empty text is refused locally")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .invalidArgument)
        }
        try await client.decline(req, reason: .noContent)
        let outcome = await press.value
        XCTAssertEqual(outcome, .fellBack(reason: "declined:noContent"))
    }
}
