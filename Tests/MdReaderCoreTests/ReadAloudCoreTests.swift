import JavaScriptCore
import XCTest
@testable import MdReaderCore

/// read-aloud-core.js: the pure helpers behind Read Aloud (text re-mapping,
/// separators, offset → text-node lookup, scroll-follow), run in
/// JavaScriptCore.
final class ReadAloudCoreTests: XCTestCase {
    private var ctx: JSContext!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(MdReaderResources.url(forResource: "read-aloud-core", withExtension: "js"))
        ctx = try XCTUnwrap(JSContext())
        ctx.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        XCTAssertNil(ctx.exception)
    }

    /// Calls `PreviewMDReadAloudCore.<function>(…args)` with JSON-encoded
    /// arguments.
    private func call(_ function: String, _ args: Any...) throws -> JSValue {
        let data = try JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let result = ctx.evaluateScript("PreviewMDReadAloudCore.\(function).apply(null, \(json))")
        XCTAssertNil(ctx.exception, "\(function): \(String(describing: ctx.exception))")
        return try XCTUnwrap(result)
    }

    private func remap(_ old: String, _ new: String, _ cur: Int) throws -> Int {
        Int(try call("remapOffset", old, new, cur).toInt32())
    }

    // MARK: remapOffset

    func testUnchangedTextKeepsOffset() throws {
        let text = "One. Two. Three."
        XCTAssertEqual(try remap(text, text, 5), 5)
        XCTAssertEqual(try remap(text, text, 16), 16)
    }

    func testEditAfterCurrentSentenceKeepsOffset() throws {
        // Reading "Two." (starts at 5); the user edits "Three".
        XCTAssertEqual(try remap("One. Two. Three.", "One. Two. Three and four.", 5), 5)
    }

    func testEditInsideCurrentSentenceAfterItsStartKeepsOffset() throws {
        XCTAssertEqual(try remap("One. Two words. Three.", "One. Two more words. Three.", 5), 5)
    }

    func testEditBeforeCurrentSentenceShiftsOffset() throws {
        // Reading "Three." at 10; four characters inserted before it.
        let old = "One. Two. Three."
        let new = "One more. Two. Three."
        XCTAssertEqual(try remap(old, new, 10), 15)
        XCTAssertEqual((new as NSString).substring(from: 15), "Three.")
        // Deletion before it.
        XCTAssertEqual(try remap(old, "Two. Three.", 10), 5)
    }

    func testEditAtCurrentSentenceStartSnapsBackToSentenceStart() throws {
        // Reading "Two words." (5); its first word is replaced.
        XCTAssertEqual(try remap("One. Two words. Four.", "One. Six words. Four.", 5), 5)
        // The edit starts before the current position: back to the start of
        // the paragraph it is in.
        let old2 = "Title\n\nFirst para here.\n\nSecond"
        let new2 = "Title\n\nFirst changed here.\n\nSecond"
        XCTAssertEqual(try remap(old2, new2, 13), 7)
    }

    func testNoBoundaryWithinReachFallsBackToFirstChange() throws {
        let long = String(repeating: "word ", count: 100)   // 500 chars, no punctuation
        let old = long + "alpha beta"
        let new = long + "gamma beta"
        XCTAssertEqual(try remap(old, new, 500), 500)
    }

    func testRemapClampsAndNeverSplitsSurrogatePairs() throws {
        XCTAssertEqual(try remap("abc", "a", 3), 1)
        XCTAssertEqual(try remap("abc", "", 2), 0)
        // 👍 (2 units) replaced by 👎: the texts share the high surrogate, so
        // the first difference is between the halves of the pair.
        XCTAssertEqual(try remap("x. 👍 y", "x. 👎 y", 4), 3)
    }

    // MARK: sentenceStartBefore

    func testSentenceStartBefore() throws {
        let text = "First one. Second “quoted.” Third\nFourth"
        func start(_ pos: Int) throws -> Int { Int(try call("sentenceStartBefore", text, pos, 300).toInt32()) }
        XCTAssertEqual(try start(5), 0)
        XCTAssertEqual(try start(14), 11)
        XCTAssertEqual(try start(30), 28)         // after ” and a space
        XCTAssertEqual(try start(36), 34)         // after the newline
        XCTAssertEqual(Int(try call("sentenceStartBefore", "abc def ghi", 10, 3).toInt32()), 10)
    }

    // MARK: separatorFor

    func testSeparatorFor() throws {
        func sep(_ text: String, _ n: Int) throws -> String { try call("separatorFor", text, n).toString() }
        XCTAssertEqual(try sep("", 2), "")
        XCTAssertEqual(try sep("a", 2), "\n\n")
        XCTAssertEqual(try sep("a\n", 2), "\n")
        XCTAssertEqual(try sep("a\n\n", 2), "")
        XCTAssertEqual(try sep("a\n\n\n", 2), "")
        XCTAssertEqual(try sep("a", 1), "\n")
        XCTAssertEqual(try sep("a\n", 1), "")
    }

    // MARK: entryIndexAt / slicesFor

    private let entries: [[String: Int]] = [
        ["start": 0, "length": 5],     // "Hello"
        ["start": 5, "length": 6],     // " world"
        ["start": 13, "length": 4],    // after a "\n\n" separator
    ]

    func testEntryIndexAt() throws {
        func index(_ offset: Int) throws -> Int { Int(try call("entryIndexAt", entries, offset).toInt32()) }
        XCTAssertEqual(try index(0), 0)
        XCTAssertEqual(try index(4), 0)
        XCTAssertEqual(try index(5), 1)
        XCTAssertEqual(try index(12), 1)   // in the separator
        XCTAssertEqual(try index(13), 2)
        XCTAssertEqual(try index(100), 2)
        XCTAssertEqual(Int(try call("entryIndexAt", [[String: Int]](), 3).toInt32()), -1)
    }

    private func slices(_ start: Int, _ end: Int) throws -> [[Int]] {
        let value = try call("slicesFor", entries, start, end)
        let array = try XCTUnwrap(value.toArray() as? [[String: Any]])
        return array.map { [($0["index"] as! NSNumber).intValue, ($0["start"] as! NSNumber).intValue,
                            ($0["end"] as! NSNumber).intValue] }
    }

    func testSlicesWithinOneEntry() throws {
        XCTAssertEqual(try slices(1, 4), [[0, 1, 4]])
    }

    func testSlicesAcrossEntriesSkipSeparators() throws {
        XCTAssertEqual(try slices(3, 8), [[0, 3, 5], [1, 0, 3]])
        XCTAssertEqual(try slices(6, 15), [[1, 1, 6], [2, 0, 2]])
        // A range that only covers the separator maps to nothing.
        XCTAssertEqual(try slices(11, 13), [])
        XCTAssertEqual(try slices(4, 4), [])
        XCTAssertEqual(try slices(16, 30), [[2, 3, 4]])
    }

    // MARK: followScrollTop

    func testFollowScrollTop() throws {
        func top(_ rectTop: Double, _ height: Double, _ scrollY: Double, _ viewport: Double) throws -> Double? {
            let v = try call("followScrollTop", rectTop, height, scrollY, viewport)
            return v.isNull ? nil : v.toDouble()
        }
        // Inside the 25–75 % band: no scroll.
        XCTAssertNil(try top(300, 20, 0, 800))
        XCTAssertNil(try top(190, 20, 1000, 800))
        // Below the band: centre goes to 40 %.
        XCTAssertEqual(try top(700, 20, 1000, 800), 1000 + 710 - 320)
        // Above the band.
        XCTAssertEqual(try top(10, 20, 1000, 800), 1000 + 20 - 320)
        // Never negative.
        XCTAssertEqual(try top(-100, 20, 0, 800), 0)
    }

    // MARK: exceedsUTF8

    func testExceedsUTF8() throws {
        func exceeds(_ text: String, _ limit: Int) throws -> Bool { try call("exceedsUTF8", text, limit).toBool() }
        XCTAssertFalse(try exceeds("abc", 3))
        XCTAssertTrue(try exceeds("abcd", 3))
        XCTAssertFalse(try exceeds("é", 2))
        XCTAssertTrue(try exceeds("éé", 3))
        XCTAssertFalse(try exceeds("👍", 4))      // one 4-byte code point (2 UTF-16 units)
        XCTAssertTrue(try exceeds("👍", 3))
        XCTAssertFalse(try exceeds("한국", 6))
        XCTAssertTrue(try exceeds("한국", 5))
    }
}
