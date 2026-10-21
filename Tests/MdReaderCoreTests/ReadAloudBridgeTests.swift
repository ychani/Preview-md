import XCTest
@testable import MdReaderCore

/// The Swift half of the read-aloud.js contract: JS builders and message
/// decoding.
final class ReadAloudBridgeTests: XCTestCase {

    func testCallsAreGuarded() {
        for js in [ReadAloudBridge.requestTextJS(request: 3), ReadAloudBridge.activateJS(generation: 2),
                   ReadAloudBridge.applyJS(word: 0..<1, sentence: nil), ReadAloudBridge.clearJS,
                   ReadAloudBridge.deactivateJS] {
            XCTAssertTrue(js.hasPrefix("(typeof PreviewMDReadAloud===\"object\""), js)
        }
        XCTAssertTrue(ReadAloudBridge.requestTextJS(request: 3).contains("PreviewMDReadAloud.requestText(3)"))
        XCTAssertTrue(ReadAloudBridge.activateJS(generation: 2).contains("activate({\"generation\":2})"))
    }

    func testApplyEncodesRanges() {
        XCTAssertTrue(ReadAloudBridge.applyJS(word: 16..<19, sentence: 0..<20)
            .contains("apply({\"word\":[16,19],\"sentence\":[0,20]})"))
        XCTAssertTrue(ReadAloudBridge.applyJS(word: nil, sentence: 22..<47)
            .contains("apply({\"word\":null,\"sentence\":[22,47]})"))
    }

    func testReattachEncodesTextSafely() throws {
        let text = "</script>\"`\\ ${x}\n\u{2028}👍"
        let js = try XCTUnwrap(ReadAloudBridge.reattachJS(text: text, word: 1..<2, sentence: nil))
        XCTAssertFalse(js.contains("</script>\""), "text must be JSON-encoded")
        XCTAssertTrue(js.contains("\"word\":[1,2],\"sentence\":null"))
        // The literal decodes back to the exact text.
        let literal = try XCTUnwrap(MarkdownRenderBridge.jsonArrayLiteral(text))
        XCTAssertTrue(js.contains("(\(literal))[0]"))
    }

    func testParseMessages() {
        XCTAssertEqual(ReadAloudBridge.parseMessage(["kind": "ready", "highlightMode": "mark"]),
                       .ready(highlightMode: "mark"))
        XCTAssertEqual(ReadAloudBridge.parseMessage(
            ["kind": "text", "text": "Hi.", "generation": NSNumber(value: 4), "request": NSNumber(value: 7),
             "utf16Length": NSNumber(value: 3)]),
            .text("Hi.", generation: 4, request: 7))
        XCTAssertEqual(ReadAloudBridge.parseMessage(
            ["kind": "textChanged", "text": "Hello.", "startOffset": NSNumber(value: 6),
             "generation": NSNumber(value: 5)]),
            .textChanged("Hello.", startOffset: 6, generation: 5))
        XCTAssertEqual(ReadAloudBridge.parseMessage(["kind": "seek", "offset": NSNumber(value: 12)]),
                       .seek(offset: 12))
        XCTAssertEqual(ReadAloudBridge.parseMessage(["kind": "error", "code": "noContent", "request": NSNumber(value: 1)]),
                       .error(code: "noContent", request: 1))
        XCTAssertEqual(ReadAloudBridge.parseMessage(["kind": "error", "code": "tooLarge", "request": NSNull()]),
                       .error(code: "tooLarge", request: nil))
    }

    func testRejectsMalformedMessages() {
        XCTAssertNil(ReadAloudBridge.parseMessage("text"))
        XCTAssertNil(ReadAloudBridge.parseMessage(["kind": "unknown"]))
        XCTAssertNil(ReadAloudBridge.parseMessage(["kind": "seek", "offset": NSNumber(value: -1)]))
        XCTAssertNil(ReadAloudBridge.parseMessage(["kind": "seek", "offset": NSNumber(value: 1.5)]))
        XCTAssertNil(ReadAloudBridge.parseMessage(["kind": "seek", "offset": "3"]))
        XCTAssertNil(ReadAloudBridge.parseMessage(["kind": "seek", "offset": kCFBooleanTrue as Any]))
        XCTAssertNil(ReadAloudBridge.parseMessage(["kind": "text", "text": "x", "generation": NSNumber(value: 1)]))
        // startOffset past the end of the text.
        XCTAssertNil(ReadAloudBridge.parseMessage(
            ["kind": "textChanged", "text": "ab", "startOffset": NSNumber(value: 3), "generation": NSNumber(value: 1)]))
    }
}
