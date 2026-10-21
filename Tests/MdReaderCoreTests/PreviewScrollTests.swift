import XCTest
@testable import MdReaderCore

final class PreviewScrollTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/notes/a.md")
    private let b = URL(fileURLWithPath: "/notes/b.md")

    func testNewDocumentStartsAtTopSameDocumentKeeps() {
        var tracker = PreviewScrollTracker()
        XCTAssertEqual(tracker.scroll(forRenderOf: a), .top)
        XCTAssertEqual(tracker.scroll(forRenderOf: a), .keep)  // typing / reload from disk
        XCTAssertEqual(tracker.scroll(forRenderOf: b), .top)   // switched documents
        XCTAssertEqual(tracker.scroll(forRenderOf: b), .keep)
        XCTAssertEqual(tracker.scroll(forRenderOf: nil), .top)
        XCTAssertEqual(tracker.scroll(forRenderOf: nil), .keep)
        XCTAssertEqual(tracker.scroll(forRenderOf: a), .top)
    }

    func testShellReloadRestoresOffsetOnceForSameDocument() {
        var tracker = PreviewScrollTracker()
        _ = tracker.scroll(forRenderOf: a)
        tracker.shellWillReload(document: a, scrollY: 1234.5)
        XCTAssertEqual(tracker.scroll(forRenderOf: a), .restore(1234.5))
        XCTAssertEqual(tracker.scroll(forRenderOf: a), .keep)
    }

    func testShellReloadForgottenWhenDocumentChanges() {
        var tracker = PreviewScrollTracker()
        _ = tracker.scroll(forRenderOf: a)
        tracker.shellWillReload(document: a, scrollY: 500)
        XCTAssertEqual(tracker.scroll(forRenderOf: b), .top)
        XCTAssertEqual(tracker.scroll(forRenderOf: a), .top)
    }

    func testShellReloadIgnoresBadOffsets() {
        var tracker = PreviewScrollTracker()
        _ = tracker.scroll(forRenderOf: a)
        for y in [nil, 0, -5, .nan, .infinity] as [Double?] {
            tracker.shellWillReload(document: a, scrollY: y)
            XCTAssertEqual(tracker.scroll(forRenderOf: a), .keep)
        }
    }

    func testRenderJSScrollOptions() throws {
        XCTAssertEqual(MarkdownRenderBridge.renderJS(for: "x", scroll: .keep), "render(([\"x\"])[0])")
        XCTAssertEqual(MarkdownRenderBridge.renderJS(for: "x", scroll: .keep),
                       MarkdownRenderBridge.renderJS(for: "x"))
        XCTAssertEqual(MarkdownRenderBridge.renderJS(for: "x", scroll: .top),
                       "render(([\"x\"])[0],{\"resetScroll\":true})")
        XCTAssertEqual(MarkdownRenderBridge.renderJS(for: "x", scroll: .restore(250)),
                       "render(([\"x\"])[0],{\"scrollY\":250.0})")
        XCTAssertEqual(MarkdownRenderBridge.renderJS(for: "x", scroll: .restore(.nan)),
                       "render(([\"x\"])[0])")
        let full = try XCTUnwrap(MarkdownRenderBridge.renderJS(
            for: "x", imageBase: nil, wikiLinks: nil, scroll: .top))
        XCTAssertTrue(full.hasSuffix("render(([\"x\"])[0],{\"resetScroll\":true})"), full)
    }
}
