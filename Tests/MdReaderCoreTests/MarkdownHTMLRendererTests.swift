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

    // MARK: - CSP (the security control)

    func testCSPBlocksScriptsAndRemoteLoads() throws {
        let doc = try MarkdownHTMLRenderer.renderDocument(markdown: "# T")
        let csp = try XCTUnwrap(cspContent(of: doc), "no CSP meta tag in: \(doc)")
        for directive in ["default-src 'none'", "script-src 'none'", "object-src 'none'",
                          "base-uri 'none'", "form-action 'none'"] {
            XCTAssertTrue(csp.contains(directive), "CSP missing \(directive): \(csp)")
        }
        XCTAssertFalse(csp.contains("https:"), "CSP must not allow remote loads: \(csp)")
        XCTAssertFalse(csp.contains("http:"), "CSP must not allow remote loads: \(csp)")
        XCTAssertFalse(csp.contains("unsafe-eval"))
    }

    private func cspContent(of doc: String) -> String? {
        guard let meta = doc.range(of: "http-equiv=\"Content-Security-Policy\" content=\""),
              let end = doc[meta.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(doc[meta.upperBound..<end])
    }

    // MARK: - sanitize() edge cases (defense-in-depth)

    private func sanitized(_ html: String) -> String {
        MarkdownHTMLRenderer.sanitize(html).lowercased()
    }

    func testSlashSeparatedHandlerStripped() {
        let out = sanitized("<img/onerror=alert(1) src=x>")
        XCTAssertFalse(out.contains("onerror"), out)
        XCTAssertFalse(out.contains("alert(1)"), out)
        XCTAssertTrue(out.contains("<img"), "the image itself should survive: \(out)")
    }

    func testHandlerAfterQuotedValueStripped() {
        let out = sanitized("<img src=\"x\"onerror=\"alert(1)\">")
        XCTAssertFalse(out.contains("onerror"), out)
    }

    func testHandlerAfterQuotedGreaterThanStripped() {
        let out = sanitized("<img alt=\">\" onerror=alert(1)>")
        XCTAssertFalse(out.contains("onerror"), out)
    }

    func testSVGOnloadStripped() {
        let out = sanitized("<svg onload=alert(1)><circle r=\"5\"/></svg>")
        XCTAssertFalse(out.contains("onload"), out)
    }

    func testSplitScriptTagCannotReassemble() {
        for input in ["<scr<script>ipt>alert(1)</script >",
                      "<scr<script></script>ipt>alert(1)</script>",
                      "<SCRIPT type=\"text/javascript\">alert(1)</SCRIPT\n>"] {
            let out = sanitized(input)
            XCTAssertFalse(out.contains("<script"), "input \(input) -> \(out)")
            XCTAssertFalse(out.contains("</script"), "input \(input) -> \(out)")
        }
    }

    func testSplitScriptInsideRawHTMLBlock() throws {
        let html = try MarkdownHTMLRenderer.renderBody(
            markdown: "<div>\n<scr<script>ipt>alert(1)</script >\n</div>\n\ntext")
            .lowercased()
        XCTAssertFalse(html.contains("<script"), html)
        XCTAssertTrue(html.contains("text"))
    }

    func testEntityEncodedJavascriptURLStripped() {
        for input in ["<a href=\"&#106;avascript:alert(1)\">x</a>",
                      "<a href=\"&#x6A;avascript&colon;alert(1)\">x</a>",
                      "<a href=\"java&#9;script:alert(1)\">x</a>",
                      "<a href=\"java\tscript:alert(1)\">x</a>",
                      "<a href=\" \u{01}JaVaScRiPt:alert(1)\">x</a>",
                      "<a href='vbscript:msgbox(1)'>x</a>",
                      "<img src=javascript:alert(1)>"] {
            let out = sanitized(input)
            XCTAssertFalse(out.contains("alert(1)") || out.contains("msgbox"),
                           "input \(input) -> \(out)")
            XCTAssertFalse(out.contains("href=") && out.contains("script"),
                           "input \(input) -> \(out)")
        }
    }

    func testEntityEncodedMarkdownLinkStripped() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "[x](&#106;avascript:alert(1))")
        let lower = html.lowercased()
        XCTAssertFalse(lower.contains("href=\"javascript") || lower.contains("href=\"&#106;"), html)
    }

    func testMetaBaseLinkStripped() {
        let out = sanitized("""
            <meta http-equiv="refresh" content="0;url=https://evil.example">
            <base href="https://evil.example/">
            <link rel="stylesheet" href="https://evil.example/x.css">
            <p>kept</p>
            """)
        for tag in ["<meta", "<base", "<link"] {
            XCTAssertFalse(out.contains(tag), "\(tag) survived: \(out)")
        }
        XCTAssertTrue(out.contains("<p>kept</p>"))
    }

    func testEmbeddingTagsStripped() {
        let out = sanitized("""
            <iframe src="https://evil.example"></iframe>
            <object data="x.swf"><param name=a value=b></object>
            <embed src="x.swf">
            <form action="https://evil.example"><input name=q></form>
            <p>kept</p>
            """)
        for tag in ["<iframe", "<object", "<embed", "<form"] {
            XCTAssertFalse(out.contains(tag), "\(tag) survived: \(out)")
        }
        XCTAssertTrue(out.contains("<p>kept</p>"))
    }

    func testSafeContentUntouched() throws {
        let markdown = """
            [site](https://example.com) ![img](data:image/png;base64,AAAA)

            The onset = 5 and javascript: the good parts.

            ```js
            let onChange = handler; img.onerror = f; const onload="x"
            ```
            """
        let html = try MarkdownHTMLRenderer.renderBody(markdown: markdown)
        XCTAssertTrue(html.contains("href=\"https://example.com\""), html)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,AAAA\""), html)
        XCTAssertTrue(html.contains("onset = 5"), html)
        XCTAssertTrue(html.contains("javascript: the good parts"), html)
        XCTAssertTrue(html.contains("let onChange = handler"), html)
        XCTAssertTrue(html.contains("img.onerror = f"), html)
        XCTAssertTrue(html.contains("const onload="), html)
    }
}
