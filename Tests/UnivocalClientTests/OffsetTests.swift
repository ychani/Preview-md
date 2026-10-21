// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient
import UnivocalMock

/// SPEC §7 / CONFORMANCE S28, S29, C7, C8: offsets are UTF-16 code units into the
/// exact text sent, never split a surrogate pair, and `\n\n` ends a sentence.
final class OffsetTests: UnivocalTestCase {

    struct Fixture {
        let text: String
        let words: [String]
        let sentences: [String]
    }

    static let fixtures: [Fixture] = [
        Fixture(text: "Revenue reached $5B.\n\nNext year looks brighter.",
                words: ["Revenue", "reached", "$5B", "$5B", "$5B", "Next", "year", "looks", "brighter"],
                sentences: ["Revenue reached $5B.", "Next year looks brighter."]),
        Fixture(text: "👍🏽 U\u{308}ni\u{308}code\r\nline",
                words: ["👍🏽", "U\u{308}ni\u{308}code", "line"],
                sentences: ["👍🏽 U\u{308}ni\u{308}code", "line"]),
        Fixture(text: "中文测试。第二句话！\n\n日本語のテキスト",
                words: ["中文测试", "第二句话", "日本語のテキスト"],
                sentences: ["中文测试。", "第二句话！", "日本語のテキスト"]),
        Fixture(text: "e\u{301}cole cafe\u{301}. Family 👨‍👩‍👧 time!",
                words: ["e\u{301}cole", "cafe\u{301}", "Family", "👨‍👩‍👧", "time"],
                sentences: ["e\u{301}cole cafe\u{301}.", "Family 👨‍👩‍👧 time!"]),
        Fixture(text: "No blank line here\nbut a single newline\n\n\nand three.",
                words: ["No", "blank", "line", "here", "but", "a", "single", "newline", "and", "three"],
                sentences: ["No blank line here", "but a single newline", "and three."]),
    ]

    func testAnalyzerReference() {
        for f in Self.fixtures {
            let a = MockTextAnalyzer.analyze(f.text)
            XCTAssertEqual(a.sentences.map { substring(f.text, $0) }, f.sentences, f.text)
            let spoken = a.words.flatMap { w in Array(repeating: substring(f.text, w.range), count: w.repeats) }
            XCTAssertEqual(spoken, f.words, f.text)
        }
    }

    func testFixturesEndToEndThroughTheSDK() async throws {
        let mock = try await startServer { $0.wordsPerMinute = 60_000 }
        let client = makeClient()
        for f in Self.fixtures {
            let session = try await client.read(ReadRequest(text: f.text))
            XCTAssertEqual(session.textUTF16Count, (f.text as NSString).length)
            let events = try await record(session).waitForFinish()
            XCTAssertEqual(events.ended?.0, .finished)
            XCTAssertEqual(events.words.map { substring(f.text, $0) }, f.words, f.text)
            XCTAssertEqual(events.sentences.map { substring(f.text, $0) }, f.sentences, f.text)
            let units = Array(f.text.utf16)
            for r in events.words + events.sentences {
                XCTAssertFalse(UTF16.isTrailSurrogate(units[r.lowerBound]), "range \(r) starts inside a surrogate pair")
                XCTAssertFalse(UTF16.isLeadSurrogate(units[r.upperBound - 1]), "range \(r) ends inside a surrogate pair")
                XCTAssertNotNil(UTF16Offsets.range(r, in: f.text))
            }
            for s in events.sentences {
                XCTAssertFalse(substring(f.text, s).contains("\n\n"), "a sentence never spans a blank line")
            }
        }
        // Logging and privacy (SPEC §13): the mock's log never contains text.
        let log = await mock.log.joined(separator: "\n")
        for needle in ["Revenue", "brighter", "code", "中文", "テキスト", "cole", "Family", "newline"] {
            XCTAssertFalse(log.contains(needle), "log leaked \(needle)")
        }
        XCTAssertTrue(log.contains("utf16="), "lengths are logged instead")
    }

    /// C7: offsets the client sends are UTF-16 indices into exactly the text it sent.
    func testSeekOffsetsAreUTF16() async throws {
        let mock = try await startServer()
        let client = makeClient()
        let text = "👍🏽👍🏽 emoji first. Then the target word."
        let session = try await client.read(ReadRequest(text: text))
        let rec = record(session)
        let target = (text as NSString).range(of: "target").location
        XCTAssertNotEqual(target, text.distance(from: text.startIndex, to: text.range(of: "target")!.lowerBound),
                          "Character counts differ from UTF-16 offsets for this fixture")
        try await session.seek(toUTF16Offset: target)
        await mock.advance(words: 1)
        let events = try await rec.wait("word") { $0.words.count == 1 }
        XCTAssertEqual(substring(text, events.words[0]), "target")
    }
}
