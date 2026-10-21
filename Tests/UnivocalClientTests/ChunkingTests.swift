// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient
import UnivocalMock

/// SPEC §8 / CONFORMANCE S30, C4.
final class ChunkingTests: UnivocalTestCase {

    func testThreeMebibyteTextIsChunkedTransparentlyWithGlobalOffsets() async throws {
        let mock = try await startServer()
        let client = makeClient()
        var text = ""
        var i = 0
        while text.utf8.count < 3 * 1_048_576 {
            text += "Paragraph \(i) has a few words in it.\n\n"
            i += 1
        }
        let session = try await client.read(ReadRequest(text: text))
        XCTAssertEqual(session.textUTF16Count, text.utf16.count)

        let log = await mock.log
        let appends = log.filter { $0.contains(" append session=\(session.id)") }
        XCTAssertGreaterThanOrEqual(appends.count, 5, "3 MiB goes out as read{more:true} + appends of ≤ 512 KiB")
        XCTAssertTrue(log.contains { $0.contains(" read session=\(session.id)") && $0.contains("more=true") })
        XCTAssertTrue(appends.last?.contains("more=false") == true)
        let sentUTF16 = log.filter { $0.contains("session=\(session.id)") && ($0.contains(" read ") || $0.contains(" append ")) }
            .compactMap { line in line.split(separator: " ").first { $0.hasPrefix("utf16=") }.flatMap { Int($0.dropFirst(6)) } }
            .reduce(0, +)
        XCTAssertEqual(sentUTF16, text.utf16.count, "the chunks concatenate to exactly the text")

        // Offsets continue globally: seek deep into a later chunk.
        let needle = "Paragraph \(i - 3) has"
        let target = (text as NSString).range(of: needle).location
        XCTAssertGreaterThan(target, 2 * 1_048_576)
        let rec = record(session)
        try await session.seek(toUTF16Offset: target)
        await mock.advance(words: 2)
        let events = try await rec.wait("words after seek") { $0.words.count == 2 }
        XCTAssertEqual(events.words.map { substring(text, $0) }, ["Paragraph", "\(i - 3)"])
        XCTAssertEqual(events.words[0].lowerBound, target)
        XCTAssertEqual(events.sentences.last.map { substring(text, $0) }, "Paragraph \(i - 3) has a few words in it.")
    }

    func testTrailingPartialSentenceIsHeldUntilTheNextChunk() async throws {
        let mock = try await startServer()
        let r = try await rawWelcomed(mock)
        let first = "Hello world. This is par"
        try r.send(["type": "read", "id": 1, "sessionId": "S", "text": .string(first), "more": true])
        _ = try await r.expectAsync("ok", timeout: 5)
        _ = try await r.expectAsync("state", timeout: 5, where: { $0.string("state") == "playing" })
        await mock.advance(words: 10)
        var got: [JSONObject] = []
        var m = try await r.nextAsync(timeout: 5)
        while let msg = m, !(msg.messageType == "state" && msg.string("state") == "loading") {
            got.append(msg)
            m = try await r.nextAsync(timeout: 5)
        }
        XCTAssertEqual(m?.string("detail"), "Waiting for text…")
        XCTAssertEqual(got.filter { $0.messageType == "word" }.map { [$0.int("start")!, $0.int("end")!] }, [[0, 5], [6, 11]],
                       "only the complete sentence is spoken before more text arrives")

        try r.send(["type": "append", "id": 2, "sessionId": "S", "text": "tial sentence. Done.", "more": false])
        _ = try await r.expectAsync("ok", timeout: 5, where: { $0["id"] == 2 })
        _ = try await r.expectAsync("state", timeout: 5, where: { $0.string("state") == "playing" })
        await mock.advance(words: 20)
        var words: [[Int]] = []
        let ended = try r.expect("ended", timeout: 5, others: { msg in
            if msg.messageType == "word" { words.append([msg.int("start")!, msg.int("end")!]) }
        })
        XCTAssertEqual(ended.string("reason"), "finished")
        let full = first + "tial sentence. Done."
        XCTAssertEqual(words.map { substring(full, $0[0]..<$0[1]) }, ["This", "is", "partial", "sentence", "Done"])
        XCTAssertEqual(words[2], [21, 28], "a word spanning the chunk boundary has its global range")
    }

    func testAppendBeyondMaxTextBytesEndsTheSession() async throws {
        let mock = try await startServer { $0.maxTextBytes = 64 }
        let r = try await rawWelcomed(mock)
        try r.send(["type": "read", "id": 1, "sessionId": "S", "text": .string(String(repeating: "a ", count: 20)), "more": true])
        _ = try await r.expectAsync("ok", timeout: 5)
        try r.send(["type": "append", "id": 2, "sessionId": "S", "text": .string(String(repeating: "b ", count: 20)), "more": false])
        let e = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e.string("code"), "limitExceeded")
        XCTAssertEqual(e["id"], 2)
        XCTAssertEqual(e.string("sessionId"), "S")
        XCTAssertEqual(e.bool("fatal"), false)
        let ended = try await r.expectAsync("ended", timeout: 5)
        XCTAssertEqual(ended.string("reason"), "error")
        // The connection stays open.
        try r.send(["type": "ping", "id": 3])
        _ = try await r.expectAsync("pong", timeout: 5)
        // A single read over the limit is refused outright.
        try r.send(["type": "read", "id": 4, "sessionId": "T", "text": .string(String(repeating: "c", count: 65))])
        let e2 = try await r.expectAsync("error", timeout: 5)
        XCTAssertEqual(e2.string("code"), "limitExceeded")
    }

    func testClientRefusesTextAboveMaxTextBytes() async throws {
        _ = try await startServer { $0.maxTextBytes = 100 }
        let client = makeClient()
        do {
            _ = try await client.read(ReadRequest(text: String(repeating: "word ", count: 30)))
            XCTFail("expected textTooLarge")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .textTooLarge)
        }
    }

    /// C4: frames never exceed maxFrameBytes even when JSON escaping doubles the text.
    func testEscapeHeavyTextIsSplitToFitFrames() async throws {
        let mock = try await startServer()
        let client = makeClient()
        let text = String(repeating: "\"\\", count: 300_000) + " end."
        let session = try await client.read(ReadRequest(text: text))
        let log = await mock.log
        let lines = log.filter { $0.contains("session=\(session.id)") && ($0.contains(" read ") || $0.contains(" append ")) }
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        let total = lines.compactMap { line in line.split(separator: " ").first { $0.hasPrefix("utf16=") }.flatMap { Int($0.dropFirst(6)) } }
            .reduce(0, +)
        XCTAssertEqual(total, text.utf16.count)
        XCTAssertFalse(log.contains { $0.contains("protocolError") })
    }
}
