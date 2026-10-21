import XCTest
import JavaScriptCore
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

    // MARK: - Front matter (markdown-extensions.js, static mode)

    func testFrontMatterRendersEscapedTable() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: """
            ---
            title: Tom & "Jerry" <b>
            draft: false
            ---
            # Body
            """)
        XCTAssertTrue(html.hasPrefix("<section class=\"front-matter\"><table>"), html)
        XCTAssertTrue(html.contains("<th scope=\"row\">title</th><td>Tom &amp; &quot;Jerry&quot; &lt;b&gt;</td>"), html)
        XCTAssertTrue(html.contains("<th scope=\"row\">draft</th><td>false</td>"), html)
        XCTAssertFalse(html.contains("<b>"), html)
        XCTAssertFalse(html.contains("<hr"), "fences must not render as rules: \(html)")
        XCTAssertTrue(html.contains("<h1>Body</h1>"), html)
    }

    func testFrontMatterListValues() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: """
            ---
            tags: [a, "b, c"]
            aliases:
              - one
              - 'two'
            nested:
              k: v
            ---
            """)
        XCTAssertTrue(html.contains(
            "<th scope=\"row\">tags</th><td><ul class=\"front-matter-list\"><li>a</li><li>b, c</li></ul></td>"), html)
        XCTAssertTrue(html.contains(
            "<th scope=\"row\">aliases</th><td><ul class=\"front-matter-list\"><li>one</li><li>two</li></ul></td>"), html)
        // Unsupported YAML (a nested mapping) is shown verbatim.
        XCTAssertTrue(html.contains("<th scope=\"row\">nested</th><td><code>  k: v</code></td>"), html)
    }

    func testFrontMatterAcceptsBOMAndDotsFence() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "\u{FEFF}---\na: 1\n...\nbody")
        XCTAssertTrue(html.contains("<th scope=\"row\">a</th><td>1</td>"), html)
        XCTAssertTrue(html.contains("<p>body</p>"), html)
    }

    func testHorizontalRuleInMiddleUnchanged() throws {
        let markdown = "para\n\n---\n\nkey: value\n\n---\n\nmore"
        let html = try MarkdownHTMLRenderer.renderBody(markdown: markdown)
        XCTAssertFalse(html.contains("front-matter"), html)
        XCTAssertEqual(html.components(separatedBy: "<hr>").count - 1, 2, html)
    }

    func testUnclosedLeadingFenceUnchanged() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "---\ntitle: x\n\ntext")
        XCTAssertFalse(html.contains("front-matter"), html)
        XCTAssertTrue(html.hasPrefix("<hr>"), html)
        XCTAssertTrue(html.contains("<p>title: x</p>"), html)
    }

    func testLeadingRuleAndSetextHeadingUnchanged() throws {
        // No `key:` line inside the fences: marked's hr + setext heading.
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "---\nJust a heading\n---\n")
        XCTAssertFalse(html.contains("front-matter"), html)
        XCTAssertTrue(html.contains("<h2>Just a heading</h2>"), html)
    }

    func testFrontMatterOnlyAtDocumentStart() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "> ---\n> a: b\n> ---\n")
        XCTAssertFalse(html.contains("front-matter"), html)
    }

    func testFrontMatterScriptInjectionEscaped() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: """
            ---
            "<script>alert(1)</script>": x
            title: "<img src=x onerror=alert(1)>"
            <script>alert(2)</script>
            ---
            """)
        XCTAssertFalse(html.lowercased().contains("<script"), html)
        XCTAssertFalse(html.lowercased().contains("<img"), html)
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"), html)
        XCTAssertTrue(html.contains("<code>&lt;script&gt;alert(2)&lt;/script&gt;</code>"), html)
    }

    // MARK: - Wikilinks (static mode)

    func testWikiLinkVariants() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "[[a]] [[a|b]] [[a#h]] [[f/a]] [[f/a#h|alias]]")
        XCTAssertEqual(html, """
            <p><span class="wikilink">a</span> <span class="wikilink">b</span> \
            <span class="wikilink">a \u{203A} h</span> <span class="wikilink">a</span> \
            <span class="wikilink">alias</span></p>

            """)
    }

    func testBacktickedWikiLinkStaysLiteral() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "see `[[x]]` and\n\n```\n[[y]]\n```")
        XCTAssertTrue(html.contains("<code>[[x]]</code>"), html)
        XCTAssertTrue(html.contains("[[y]]"), html)
        XCTAssertFalse(html.contains("wikilink"), html)
    }

    func testImageEmbedRendersAsMarkedImgInStaticMode() throws {
        let html = try MarkdownHTMLRenderer.renderBody(
            markdown: "![[x.png]] ![[pics/my y.jpg|300]] ![[z.png|200x100]] ![[a.png|Alt]] ![[note]]")
        XCTAssertTrue(html.contains("<img src=\"x.png\" alt=\"x.png\" data-previewmd-embed=\"\">"), html)
        XCTAssertTrue(html.contains(
            "<img src=\"pics/my%20y.jpg\" alt=\"my y.jpg\" width=\"300\" data-previewmd-embed=\"\">"), html)
        XCTAssertTrue(html.contains(
            "<img src=\"z.png\" alt=\"z.png\" width=\"200\" height=\"100\" data-previewmd-embed=\"\">"), html)
        XCTAssertTrue(html.contains("alt=\"Alt\""), html)
        // Note embeds stay text.
        XCTAssertTrue(html.contains("<span class=\"wikilink\">note</span>"), html)
    }

    func testImageEmbedTargetIsEscaped() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "![[a\"onerror=x.png]]")
        XCTAssertFalse(html.contains("\"onerror"), html)
        XCTAssertFalse(html.lowercased().contains(" onerror="), html)
    }

    // MARK: - Quick Look image blocking

    func testCSPAllowsOnlyCidAndDataImages() throws {
        let doc = try MarkdownHTMLRenderer.renderDocument(markdown: "# T")
        let csp = try XCTUnwrap(cspContent(of: doc))
        XCTAssertTrue(csp.contains("img-src cid: data:;"), csp)
        XCTAssertFalse(csp.contains("file:"), csp)
    }

    func testRemoteAndFileImagesRemovedFromDocument() throws {
        let doc = try MarkdownHTMLRenderer.renderDocument(markdown: """
            [link](https://example.com/page)

            ![r](https://example.com/a.png) ![f](file:///etc/a.png) ![rel](../a.png)
            <img src="http://x/t.gif" srcset="https://x/2x.png 2x" alt="raw">
            <img src="data:image/png;base64,AAAA" alt="inline">
            <video poster="https://x/p.png" src="https://x/v.mp4"></video>
            <p style="background:url(https://x/bg.png)">s</p>
            <p style="color: red">ok</p>
            <table background="https://x/t.png"><tr><td>c</td></tr></table>
            <svg><image href="https://x/i.png"/><use xlink:href="https://x/u.svg#a"/></svg>
            """, title: "t.md", imageFolder: nil).html
        let body = try XCTUnwrap(doc.components(separatedBy: "<body>").last)
        for leak in ["https://x/", "http://x/", "example.com/a.png", "file:///", "../a.png", "srcset"] {
            XCTAssertFalse(body.contains(leak), "\(leak) survived: \(body)")
        }
        XCTAssertTrue(body.contains("alt=\"r\""), body)
        XCTAssertTrue(body.contains("src=\"data:image/png;base64,AAAA\""), body)
        XCTAssertTrue(body.contains("style=\"color: red\""), body)
        XCTAssertTrue(body.contains("href=\"https://example.com/page\""), "links are not loads: \(body)")
    }

    func testWikiLinkAliasInjectionEscaped() throws {
        let html = try MarkdownHTMLRenderer.renderBody(
            markdown: "[[a|<img src=x onerror=alert(1)>]] [[<script>alert(2)</script>]]")
        XCTAssertFalse(html.lowercased().contains("<img"), html)
        XCTAssertFalse(html.lowercased().contains("<script"), html)
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"), html)
    }

    func testWikiLinkInTableWithEscapedPipe() throws {
        let html = try MarkdownHTMLRenderer.renderBody(markdown: "| c |\n|---|\n| [[a\\|b]] |")
        XCTAssertTrue(html.contains("<td><span class=\"wikilink\">b</span></td>"), html)
    }

    // MARK: - Code block language label

    func testCodeBlockLabelIsPlainLanguageName() throws {
        let html = try MarkdownHTMLRenderer.renderBody(
            markdown: "```mermaid\ngraph TD; A-->B\n```\n\n```swift\nlet x = 1\n```\n\n```\nplain\n```")
        // Label attribute carries just the name; the code class is unchanged.
        XCTAssertTrue(html.contains("<pre data-lang=\"mermaid\"><code class=\"language-mermaid\">"), html)
        XCTAssertTrue(html.contains("<pre data-lang=\"swift\"><code class=\"language-swift\">"), html)
        XCTAssertFalse(html.contains("data-lang=\"language-"), html)
        // Mermaid source stays visible in Quick Look (no JS to render it).
        XCTAssertTrue(html.contains("graph TD; A--&gt;B"), html)
        // Unlabeled fence: no label.
        XCTAssertTrue(html.contains("<pre><code>plain"), html)
        XCTAssertEqual(html.components(separatedBy: "data-lang=").count - 1, 2, html)
    }

    func testCodeBlockLabelCSSUsesDataLangNotClass() throws {
        let doc = try MarkdownHTMLRenderer.renderDocument(markdown: "```swift\nx\n```")
        XCTAssertTrue(doc.contains("content: attr(data-lang)"), "label must come from data-lang")
        XCTAssertFalse(doc.contains("content: attr(class)"), "class-based label shows LANGUAGE-…")
    }

    func testRenderDocumentIncludesExtensionStyles() throws {
        let doc = try MarkdownHTMLRenderer.renderDocument(markdown: "[[a]]")
        XCTAssertTrue(doc.contains(".front-matter"), "preview.css front-matter styles not inlined")
        XCTAssertTrue(doc.contains(".wikilink"), "preview.css wikilink styles not inlined")
    }

    // MARK: - App mode (same script preview.html loads), exercised in JSC

    /// marked + markdown-extensions.js in app mode with a resolver backed by
    /// `map` (nil → no map, i.e. state "unknown"). DOMPurify and the
    /// previewmd-local: rewrite need a DOM, so they're out of scope here.
    private func renderAppMode(_ markdown: String, map: [String: [String: String]]?) throws -> String {
        let ctx = try XCTUnwrap(JSContext())
        var error: String?
        ctx.exceptionHandler = { _, e in error = e?.toString() }
        for name in ["marked.min", "markdown-extensions"] {
            let url = try XCTUnwrap(MdReaderResources.url(forResource: name, withExtension: "js"))
            ctx.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        }
        if let map {
            ctx.setObject(map, forKeyedSubscript: "__map" as NSString)
            ctx.evaluateScript("""
                var __resolve = function (t) {
                  return Object.prototype.hasOwnProperty.call(__map, t) ? __map[t] : null;
                };
                """)
        } else {
            ctx.evaluateScript("var __resolve = null;")
        }
        ctx.evaluateScript("""
            PreviewMDExtensions.install(marked, { mode: 'app', resolve: __resolve, rootRelativeMarker: 'TOKEN' });
            """)
        ctx.setObject(markdown, forKeyedSubscript: "__md" as NSString)
        let out = ctx.evaluateScript("marked.parse(__md)")?.toString() ?? ""
        XCTAssertNil(error)
        return out
    }

    func testAppModeCodeBlockLabel() throws {
        let html = try renderAppMode("```swift\nx\n```", map: nil)
        XCTAssertTrue(html.contains("<pre data-lang=\"swift\"><code class=\"language-swift\">"), html)
    }

    func testAppModeWikiLinkStates() throws {
        let html = try renderAppMode("[[a#h|A]] [[gone]] [[#Local]]",
                                     map: ["a": ["path": "notes/a.md", "kind": "note"]])
        XCTAssertTrue(html.contains(
            "<a class=\"wikilink\" data-wikilink=\"a#h\" data-state=\"resolved\" role=\"link\" tabindex=\"0\">A</a>"), html)
        XCTAssertTrue(html.contains("data-wikilink=\"gone\" data-state=\"missing\""), html)
        XCTAssertTrue(html.contains("data-wikilink=\"#Local\" data-state=\"resolved\""), html)
        XCTAssertFalse(html.contains("href="), "wikilinks carry no href: \(html)")
    }

    func testAppModeWithoutMapIsUnknown() throws {
        let html = try renderAppMode("[[a]] ![[pic one.png]]", map: nil)
        XCTAssertTrue(html.contains("data-wikilink=\"a\" data-state=\"unknown\""), html)
        // No map: embed falls back to a document-relative src.
        XCTAssertTrue(html.contains("<img src=\"pic%20one.png\" alt=\"pic one.png\">"), html)
    }

    func testAppModeImageEmbeds() throws {
        let html = try renderAppMode("![[x.png|200x100]] ![[y.png]] ![[z.png|Alt <b>]]", map: [
            "x.png": ["path": "assets/x y.png", "kind": "image"],
            "z.png": ["path": "z.png", "kind": "image"],
        ])
        XCTAssertTrue(html.contains(
            "<img src=\"assets/x%20y.png\" data-previewmd-root-relative=\"TOKEN\" alt=\"x.png\" width=\"200\" height=\"100\">"), html)
        XCTAssertTrue(html.contains("<span class=\"wikilink-missing-image\" title=\"Image not found\">y.png</span>"), html)
        XCTAssertTrue(html.contains("alt=\"Alt &lt;b&gt;\""), html)
    }
}
