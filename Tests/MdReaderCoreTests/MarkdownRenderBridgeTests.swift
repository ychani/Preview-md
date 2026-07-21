import XCTest
@testable import MdReaderCore

final class MarkdownRenderBridgeTests: XCTestCase {

    private func roundTrip(_ markdown: String) throws -> String {
        let js = try XCTUnwrap(MarkdownRenderBridge.renderJS(for: markdown))
        XCTAssertTrue(js.hasPrefix("render(("), "unexpected shape: \(js)")
        XCTAssertTrue(js.hasSuffix(")[0])"), "unexpected shape: \(js)")
        // Extract the JSON array literal and decode it back — what render()
        // receives must be byte-identical to the input.
        let jsonPart = String(js.dropFirst("render((".count).dropLast(")[0])".count))
        let decoded = try JSONSerialization.jsonObject(with: Data(jsonPart.utf8)) as? [String]
        return try XCTUnwrap(decoded?.first)
    }

    func testPlainText() throws {
        XCTAssertEqual(try roundTrip("# Hello"), "# Hello")
    }

    func testQuotesBackticksBackslashes() throws {
        let nasty = #"He said "hi" — `code` \ and \\ and 'single'"#
        XCTAssertEqual(try roundTrip(nasty), nasty)
    }

    func testNewlinesAndTabs() throws {
        let text = "line1\nline2\r\nline3\ttabbed"
        XCTAssertEqual(try roundTrip(text), text)
    }

    func testScriptInjectionAttempt() throws {
        let text = "</script><script>alert(1)</script>"
        XCTAssertEqual(try roundTrip(text), text)
    }

    func testUnicode() throws {
        let text = "한국어 · émoji 🚀 · 中文 · \u{2028}line-sep"
        XCTAssertEqual(try roundTrip(text), text)
    }

    func testEmptyString() throws {
        XCTAssertEqual(try roundTrip(""), "")
    }
}
