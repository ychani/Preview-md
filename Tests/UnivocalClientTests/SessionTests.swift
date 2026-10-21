// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient
import UnivocalMock

final class SessionTests: UnivocalTestCase {

    static let spec = "Revenue reached $5B.\n\nNext year looks brighter."

    // MARK: Lifecycle (S19, S26, C8)

    func testReadLoadingPlayingSentenceThenWords() async throws {
        let mock = try await startServer()
        let client = makeClient()
        let text = Self.spec
        let session = try await client.read(ReadRequest(text: text))
        XCTAssertEqual(session.textUTF16Count, 47)
        let rec = record(session)
        try await rec.wait("playing") { $0.states == [.loading, .playing] }
        let first = await rec.items.first
        XCTAssertEqual(first, .state(.loading, detail: "Starting speech engine…"), "the first event is state{loading}")

        await mock.advance(words: 3)
        var events = try await rec.wait("3 words") { $0.words.count == 3 }
        XCTAssertEqual(Array(events.dropFirst(2)), [.sentence(0..<20), .word(0..<7), .word(8..<15), .word(16..<19)])

        // `$5B` is spoken as three words with the identical source range (SPEC §5.7).
        await mock.advance(words: 2)
        events = try await rec.wait("5 words") { $0.words.count == 5 }
        XCTAssertEqual(events.words.suffix(3), [16..<19, 16..<19, 16..<19])

        await mock.advance(words: 10)
        events = try await rec.waitForFinish()
        XCTAssertEqual(events.sentences, [0..<20, 22..<47])
        XCTAssertEqual(events.words.map { substring(text, $0) }, ["Revenue", "reached", "$5B", "$5B", "$5B", "Next", "year", "looks", "brighter"])
        XCTAssertEqual(events.ended?.0, .finished)
        XCTAssertTrue(session.isEnded)
        let owner = await mock.activeSessionOwner
        XCTAssertNil(owner)
    }

    func testRealClockReadsEveryWordInOrder() async throws {
        _ = try await startServer { $0.wordsPerMinute = 60_000 }
        let client = makeClient()
        let text = "The quick brown fox. Jumps over the lazy dog!\nAnd then it rests."
        let session = try await client.read(ReadRequest(text: text))
        let events = try await record(session).waitForFinish()
        XCTAssertEqual(events.words.map { substring(text, $0) },
                       ["The", "quick", "brown", "fox", "Jumps", "over", "the", "lazy", "dog", "And", "then", "it", "rests"])
        XCTAssertEqual(events.sentences.map { substring(text, $0) },
                       ["The quick brown fox.", "Jumps over the lazy dog!", "And then it rests."])
        assertSentenceBeforeWords(events)
    }

    // MARK: Controls (S23, S24, S25)

    func testPauseResumeSeekSetRateStop() async throws {
        let mock = try await startServer()
        let client = makeClient()
        let text = Self.spec
        let session = try await client.read(ReadRequest(text: text))
        let rec = record(session)
        try await rec.wait("playing") { $0.states.last == .playing }
        await mock.advance(words: 1)

        try await session.pause()
        try await rec.wait("paused") { $0.states.last == .paused }
        try await session.pause()   // no-op in paused, still ok
        await mock.advance(words: 5)   // the clock does not run while paused
        var events = await rec.items
        XCTAssertEqual(events.words.count, 1)

        try await session.resume()
        try await rec.wait("playing again") { $0.states.last == .playing }
        try await session.resume()   // no-op in playing

        // Seek into "year" keeps playing and continues from the word containing the offset.
        try await session.seek(toUTF16Offset: 28)
        await mock.advance(words: 1)
        events = try await rec.wait("word after seek") { $0.words.count == 2 }
        XCTAssertEqual(events.words.last, 27..<31)
        XCTAssertEqual(events.sentences.last, 22..<47, "the sentence is re-announced before the first word after a seek")
        XCTAssertEqual(events.states.last, .playing)

        try await session.setRate(100)
        events = try await rec.wait("rate") { $0.contains(.rate(4.0)) }
        try await session.setRate(0.01)
        events = try await rec.wait("rate min") { $0.contains(.rate(0.25)) }

        do {
            try await session.seek(toUTF16Offset: 999)
            XCTFail("expected invalidOffset")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .invalidOffset)
        }

        try await session.stop()
        events = try await rec.waitForFinish()
        XCTAssertEqual(events.ended?.0, .stopped)
        XCTAssertEqual(events.last, .ended(.stopped, by: nil), "ended is the last event")
        do {
            try await session.resume()
            XCTFail("expected sessionEnded")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .sessionEnded)
        }
    }

    func testServerRejectsOutOfRangeSeekAndBadArguments() async throws {
        let mock = try await startServer()
        let r = try await rawWelcomed(mock)
        try r.send(["type": "read", "id": 1, "sessionId": "S", "text": "Short text."])
        _ = try await r.expectAsync("ok", timeout: 5)
        try r.send(["type": "seek", "id": 2, "sessionId": "S", "offset": 12])
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "invalidOffset")
        XCTAssertEqual(e.bool("fatal"), false)
        XCTAssertEqual(e["id"], 2)
        XCTAssertEqual(e.string("sessionId"), "S")
        try r.send(["type": "seek", "id": 3, "sessionId": "S", "offset": 11])   // == length is allowed
        let ok = try await r.expectAsync("ok", timeout: 5, where: { $0["id"] == 3 })
        XCTAssertEqual(ok.string("sessionId"), "S")
        try r.send(["type": "setRate", "id": 4, "sessionId": "S", "rate": "fast"])
        let bad = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(bad.string("code"), "invalidArgument")
        XCTAssertEqual(bad.string("field"), "rate")
        try r.send(["type": "read", "id": 5, "text": "No session id."])
        let missing = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(missing.string("field"), "sessionId")
        try r.send(["type": "read", "id": 6, "sessionId": "T", "text": "Hi.", "startOffset": 50])
        let start = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(start.string("code"), "invalidOffset")
    }

    func testStartOffsetBeginsAtContainingSentence() async throws {
        let mock = try await startServer()
        let client = makeClient()
        var req = ReadRequest(text: Self.spec)
        req.startOffset = 30   // inside "looks"
        let session = try await client.read(req)
        let rec = record(session)
        await mock.advance(words: 1)
        let events = try await rec.wait("first word") { $0.words.count == 1 }
        XCTAssertEqual(events.sentences.first, 22..<47)
        XCTAssertEqual(events.words.first, 22..<26)
    }

    // MARK: Ownership and preemption (S19, S20, S22, S27, C10)

    func testSessionExistsAndClientSideGuards() async throws {
        let mock = try await startServer()
        let client = makeClient()
        var req = ReadRequest(text: "Hello there.")
        req.sessionId = "fixed"
        _ = try await client.read(req)
        do {
            _ = try await client.read(req)
            XCTFail("expected sessionExists")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .sessionExists)
        }
        do {
            _ = try await client.read(ReadRequest(text: ""))
            XCTFail("expected invalidArgument")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .invalidArgument)
        }

        // Server-side check with a raw client.
        let r = try await rawWelcomed(mock)
        try r.send(["type": "read", "id": 1, "sessionId": "dup", "text": "One."])
        _ = try await r.expectAsync("ok", timeout: 5)
        try r.send(["type": "read", "id": 2, "sessionId": "dup", "text": "Two."])
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "sessionExists")
    }

    func testNotOwnerAndNoSession() async throws {
        let mock = try await startServer()
        let owner = makeClient(id: "com.example.owner")
        let session = try await owner.read(ReadRequest(text: "Owned by the first client."))
        let r = try await rawWelcomed(mock, id: "com.example.intruder")
        try r.send(["type": "pause", "id": 1, "sessionId": .string(session.id)])
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "notOwner")
        XCTAssertEqual(e.bool("fatal"), false)
        try r.send(["type": "stop", "id": 2, "sessionId": "nope"])
        let e2 = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e2.string("code"), "noSession")
        // The intruder learned nothing else about the session (S27).
        try r.send(["type": "ping", "id": 3])
        var others: [JSONObject] = []
        _ = try r.expect("pong", timeout: 5, others: { others.append($0) })
        XCTAssertTrue(others.isEmpty)
    }

    func testBusyWhenPreemptIsFalse() async throws {
        _ = try await startServer()
        let first = makeClient(id: "com.example.first")
        let second = makeClient(id: "com.example.second")
        let s1 = try await first.read(ReadRequest(text: "First reader."))
        var req = ReadRequest(text: "Second reader.")
        req.preempt = false
        do {
            _ = try await second.read(req)
            XCTFail("expected busy")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .busy)
        }
        XCTAssertFalse(s1.isEnded)
    }

    func testPreemptionEndsFirstOwnersSessionOnly() async throws {
        let mock = try await startServer()
        let first = makeClient(id: "com.example.first", name: "First")
        let second = makeClient(id: "com.example.second", name: "Second")
        let s1 = try await first.read(ReadRequest(text: "First reader is reading."))
        let r1 = record(s1)
        try await r1.wait("playing") { $0.states.last == .playing }

        let s2 = try await second.read(ReadRequest(text: "Second reader takes over."))
        let r2 = record(s2)
        let e1 = try await r1.waitForFinish()
        XCTAssertEqual(e1.ended?.0, .preempted)
        XCTAssertEqual(e1.ended?.1, "Second")
        await mock.advance(words: 2)
        let e2 = try await r2.wait("second's words") { $0.words.count == 2 }
        XCTAssertFalse(e2.hasEnded)
        let finalFirst = await r1.items
        XCTAssertEqual(finalFirst.words.count, 0, "nothing from the second session leaked to the first owner")
        let owner = await mock.activeSessionOwner
        XCTAssertEqual(owner, "com.example.second")
    }

    func testUnivocalOwnReadingPreempts() async throws {
        let mock = try await startServer()
        let client = makeClient()
        let session = try await client.read(ReadRequest(text: "About to be interrupted by a hotkey."))
        let rec = record(session)
        await mock.preemptFromUnivocal()
        let events = try await rec.waitForFinish()
        XCTAssertEqual(events.ended?.0, .preempted)
        XCTAssertEqual(events.ended?.1, "Univocal")
    }

    // MARK: Capabilities (C11)

    func testListVoicesAndCapabilityGate() async throws {
        _ = try await startServer()
        let client = makeClient()
        let voices = try await client.listVoices()
        XCTAssertEqual(voices.map(\.id), ["mock_alice", "mock_bob"])
        XCTAssertEqual(voices.first?.lang, "en-US")

        let other = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: other) }
        _ = try await startServer(in: other) { $0.capabilities = ["word-events", "sentence-events"] }
        let limited = makeClient(directory: other)
        do {
            _ = try await limited.listVoices()
            XCTFail("expected invalidArgument")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .invalidArgument)
        }
        var req = ReadRequest(text: "Panel requested.")
        req.showPanel = true
        _ = try await limited.read(req)   // ui:"panel" is not sent without capability `panel`
    }

    func testPanelRequestIsSentWhenAnnounced() async throws {
        let mock = try await startServer()
        let client = makeClient()
        var req = ReadRequest(text: "Show the panel.")
        req.showPanel = true
        req.title = "Secret Title"
        _ = try await client.read(req)
        let log = await mock.log
        XCTAssertTrue(log.contains { $0.contains("ui=panel") })
        XCTAssertFalse(log.contains { $0.contains("Secret Title") }, "meta.title is never logged")
    }

    func testEventsAreGatedByClientCapabilities() async throws {
        let mock = try await startServer()
        let client = makeClient { $0.clientCapabilities = ["word-events"] }   // no sentence-events
        let session = try await client.read(ReadRequest(text: "One two. Three four."))
        let rec = record(session)
        await mock.advance(words: 10)
        let events = try await rec.waitForFinish()
        XCTAssertEqual(events.words.count, 4)
        XCTAssertTrue(events.sentences.isEmpty)
    }

    func testProgressOnlyWhenRequested() async throws {
        let mock = try await startServer()
        let withProgress = makeClient { $0.clientCapabilities.insert("progress") }
        let session = try await withProgress.read(ReadRequest(text: "Alpha beta gamma delta."))
        let rec = record(session)
        try await rec.wait("playing") { $0.states.last == .playing }
        try await Task.sleep(for: .milliseconds(1050))   // progress is at most once per second
        await mock.advance(words: 1)
        let events = try await rec.wait("progress") { $0.contains { if case .progress = $0 { return true } else { return false } } }
        XCTAssertTrue(events.contains(.progress(offset: 5)))

        let without = makeClient(id: "com.example.noprogress")
        let s2 = try await without.read(ReadRequest(text: "Alpha beta gamma delta."))
        let r2 = record(s2)
        try await r2.wait("playing") { $0.states.last == .playing }
        try await Task.sleep(for: .milliseconds(1050))
        await mock.advance(words: 10)
        let e2 = try await r2.waitForFinish()
        XCTAssertFalse(e2.contains { if case .progress = $0 { return true } else { return false } })
    }

    // MARK: Helpers

    private func assertSentenceBeforeWords(_ events: [ReadingEvent], file: StaticString = #filePath, line: UInt = #line) {
        var current: Range<Int>?
        for e in events {
            switch e {
            case .sentence(let r): current = r
            case .word(let w):
                guard let s = current else { return XCTFail("word before any sentence", file: file, line: line) }
                XCTAssertTrue(s.lowerBound <= w.lowerBound && w.upperBound <= s.upperBound, "word \(w) outside sentence \(s)", file: file, line: line)
            default: break
            }
        }
    }
}
