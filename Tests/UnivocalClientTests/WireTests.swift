// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient

final class WireTests: XCTestCase {

    func testEncodeDecodeRoundTripKeepsTypesAndUnknownFields() throws {
        let msg: JSONObject = [
            "type": "word", "sessionId": "S1", "start": 16, "end": 19, "rate": 1.5, "flag": true,
            "nothing": nil, "x-future": ["nested": [1, "two", 3.25]],
        ]
        let frame = try UnivocalWire.frame(msg)
        XCTAssertEqual(frame.last, 0x0A)
        XCTAssertEqual(frame.filter { $0 == 0x0A }.count, 1, "exactly one newline: the terminator")
        let back = try UnivocalWire.decode(frame.dropLast())
        XCTAssertEqual(back, msg)
        XCTAssertEqual(back.int("start"), 16)
        XCTAssertEqual(back.double("rate"), 1.5)
        XCTAssertEqual(back.bool("flag"), true)
        XCTAssertEqual(back["nothing"], .null)
    }

    func testTextWithNewlinesNeverProducesARawNewline() throws {
        let frame = try UnivocalWire.encode(["type": "read", "text": "line one\nline two\r\n\n"])
        XCTAssertFalse(frame.contains(0x0A))
        XCTAssertEqual(try UnivocalWire.decode(frame).string("text"), "line one\nline two\r\n\n")
    }

    func testDecodeRejectsMalformedAndNonObjects() {
        XCTAssertThrowsError(try UnivocalWire.decode(Data("{\"type\": oops".utf8)))
        XCTAssertThrowsError(try UnivocalWire.decode(Data("[1,2]".utf8)))
        XCTAssertThrowsError(try UnivocalWire.decode(Data("\"str\"".utf8)))
    }

    func testDecodeToleratesCarriageReturn() throws {
        XCTAssertEqual(try UnivocalWire.decode(Data("{\"type\":\"pong\",\"id\":1}\r".utf8)).messageType, "pong")
    }

    func testIntegralDoublesReadAsInts() {
        XCTAssertEqual(JSONValue.double(7).intValue, 7)
        XCTAssertNil(JSONValue.double(7.5).intValue)
        XCTAssertEqual(JSONValue.int(3).doubleValue, 3)
    }

    // MARK: Framer

    func testFramerSplitsCRLFAndPartialFrames() throws {
        var f = NDJSONFramer(maxFrameBytes: 1024)
        XCTAssertEqual(try f.push(Data("{\"a\":1}\r\n{\"b\"".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}"])
        XCTAssertEqual(try f.push(Data(":2}\n\n{\"c\":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"b\":2}", "{\"c\":3}"])
        XCTAssertEqual(f.pendingByteCount, 0)
    }

    func testFramerAcceptsExactlyMaxAndRefusesLarger() throws {
        var ok = NDJSONFramer(maxFrameBytes: 10)
        XCTAssertEqual(try ok.push(Data("123456789\n".utf8)).count, 1, "10 bytes including the newline fit")
        var tooBig = NDJSONFramer(maxFrameBytes: 10)
        XCTAssertThrowsError(try tooBig.push(Data("1234567890\n".utf8)))
        var partial = NDJSONFramer(maxFrameBytes: 10)
        XCTAssertNoThrow(try partial.push(Data("123456789".utf8)))
        XCTAssertThrowsError(try partial.push(Data("0".utf8)), "a partial frame that can no longer fit is refused early")
    }

    func testFramerByteAtATime() throws {
        var f = NDJSONFramer(maxFrameBytes: 100)
        var frames: [Data] = []
        for b in Data("{\"type\":\"ping\"}\n{\"type\":\"pong\"}\n".utf8) { frames += try f.push(Data([b])) }
        XCTAssertEqual(frames.count, 2)
    }

    // MARK: Chunker (SPEC §8, CONFORMANCE C4)

    func testChunkerConcatenatesExactlyAndPrefersParagraphs() {
        let para = String(repeating: "Sentence one. ", count: 20) + "\n\n"
        let text = String(repeating: para, count: 50) + "Tail 👍🏽 é\u{301}."
        let chunks = TextChunker.chunks(text, maxUTF8: 1000)
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertEqual(chunks.joined(), text)
        for c in chunks.dropLast() {
            XCTAssertLessThanOrEqual(c.utf8.count, 1000)
            XCTAssertTrue(c.hasSuffix("\n\n"), "cut after a blank line when one is available")
        }
    }

    func testChunkerNeverSplitsAScalar() {
        let text = String(repeating: "👍🏽", count: 1000)   // 8 UTF-8 bytes per pair, no spaces
        let chunks = TextChunker.chunks(text, maxUTF8: 101)
        XCTAssertEqual(chunks.joined(), text)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.utf8.count, 101)
            XCTAssertEqual(c.utf16.count % 2, 0, "no lone surrogate")
        }
    }

    func testChunkerShortTextIsOnePiece() {
        XCTAssertEqual(TextChunker.chunks("Hello.", maxUTF8: 512 * 1024), ["Hello."])
    }

    // MARK: UTF-16 offsets (SPEC §7)

    func testUTF16RangeConversion() throws {
        let text = "Revenue reached $5B.\n\nNext 👍🏽 year."
        XCTAssertEqual(substring(text, 16..<19), "$5B")
        XCTAssertEqual(UTF16Offsets.utf16Count(text), (text as NSString).length)
        XCTAssertNil(UTF16Offsets.range(0..<999, in: text))
        XCTAssertNil(UTF16Offsets.range(-1..<2, in: text))
        XCTAssertEqual(UTF16Offsets.nsRange(16..<19), NSRange(location: 16, length: 3))
        // A range that would split the 👍 surrogate pair is widened outward.
        let thumb = (text as NSString).range(of: "👍", options: .literal)
        let split = (thumb.location + 1)..<(thumb.location + 2)
        let widened = try XCTUnwrap(UTF16Offsets.range(split, in: text))
        XCTAssertEqual(String(text[widened]), "👍")
    }
}
