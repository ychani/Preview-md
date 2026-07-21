import XCTest
@testable import MdReaderCore

final class MarkdownHTMLRendererTests: XCTestCase {

    func testBasicRendering() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "# Hello\n\nSome **bold** text.")
        XCTAssertTrue(html.contains("<h1"), "missing h1 in: \(html)")
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
    }

    func testGFMTable() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<table"), "GFM tables should render: \(html)")
    }

    func testScriptStripped() throws {
        let html = try MarkdownHTMLRenderer.renderBody(
            markdown: "hi\n\n<script>alert(1)</script>\n\n<img src=x onerror=\"alert(2)\">")
        XCTAssertFalse(html.lowercased().contains("<script"))
        XCTAssertFalse(html.lowercased().contains("onerror"))
    }

    func testJavascriptURLStripped() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "[x](javascript:alert(1))")
        XCTAssertFalse(html.lowercased().contains("javascript:alert"))
    }

    func testFullDocumentStructure() throws {
        let doc = try MarkdownHTMLRenderer.renderDocument(markdown: "# T", title: "file.md")
        XCTAssertTrue(doc.contains("<!DOCTYPE html>"))
        XCTAssertTrue(doc.contains("Content-Security-Policy"))
        XCTAssertTrue(doc.contains("markdown-body"))
        XCTAssertTrue(doc.contains("<style>"), "preview.css should be inlined")
    }

    func testUnicodeContent() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "# 한국어 🚀")
        XCTAssertTrue(html.contains("한국어"))
    }
}
