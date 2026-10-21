import JavaScriptCore
import WebKit
import XCTest
@testable import MdReaderCore

/// `remoteImageRefCount` (markdown-extensions.js) decides whether the app
/// preview shows the "Load remote images" banner. Pure function, run in
/// JavaScriptCore.
final class RemoteImageDetectionTests: XCTestCase {
    private var ctx: JSContext!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(MdReaderResources.url(forResource: "markdown-extensions", withExtension: "js"))
        ctx = try XCTUnwrap(JSContext())
        ctx.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        XCTAssertNil(ctx.exception)
    }

    private func count(_ tag: String, _ attrs: [String: String]) throws -> Int32 {
        let data = try JSONSerialization.data(withJSONObject: attrs)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let tagJSON = try XCTUnwrap(MarkdownRenderBridge.jsonArrayLiteral(tag))
        let result = ctx.evaluateScript("""
            (function (a) {
              return PreviewMDExtensions.remoteImageRefCount((\(tagJSON))[0], function (n) {
                return Object.prototype.hasOwnProperty.call(a, n) ? a[n] : null;
              });
            })(\(json))
            """)
        XCTAssertNil(ctx.exception)
        return try XCTUnwrap(result).toInt32()
    }

    func testImgSrc() throws {
        XCTAssertEqual(try count("img", ["src": "https://img.shields.io/badge/macOS-13%2B-blue"]), 1)
        XCTAssertEqual(try count("IMG", ["src": "  HTTPS://example.com/x.png"]), 1)
        XCTAssertEqual(try count("img", ["src": "ht\ntps://example.com/x.png"]), 1)
        XCTAssertEqual(try count("img", ["src": "local.png"]), 0)
        XCTAssertEqual(try count("img", ["src": "previewmd-local://abc/x.png"]), 0)
        XCTAssertEqual(try count("img", ["src": "data:image/png;base64,AAAA"]), 0)
        // The opt-in only allows https:, so http: never offers the banner.
        XCTAssertEqual(try count("img", ["src": "http://example.com/x.png"]), 0)
    }

    func testSrcset() throws {
        XCTAssertEqual(try count("img", ["srcset": "a.png 1x, https://example.com/b.png 2x"]), 1)
        XCTAssertEqual(try count("source", ["srcset": "https://example.com/a.webp"]), 1)
        XCTAssertEqual(try count("source", ["srcset": "a.webp 1x, b.webp 2x"]), 0)
        XCTAssertEqual(try count("img", ["src": "https://e.com/a.png", "srcset": "https://e.com/b.png 2x"]), 2)
    }

    func testOtherImageAttributes() throws {
        XCTAssertEqual(try count("video", ["poster": "https://example.com/p.jpg"]), 1)
        XCTAssertEqual(try count("input", ["type": "image", "src": "https://example.com/b.png"]), 1)
        XCTAssertEqual(try count("table", ["background": "https://example.com/bg.png"]), 1)
        XCTAssertEqual(try count("image", ["href": "https://example.com/s.png"]), 1)
        XCTAssertEqual(try count("feimage", ["xlink:href": "https://example.com/s.png"]), 1)
        // Links are navigation, not image loads.
        XCTAssertEqual(try count("a", ["href": "https://example.com/"]), 0)
        XCTAssertEqual(try count("source", ["src": "https://example.com/v.mp4"]), 0)
    }

    func testInlineStyleURLs() throws {
        XCTAssertEqual(try count("div", ["style": "background-image: url('https://e.com/a.png')"]), 1)
        XCTAssertEqual(try count("div", ["style": "background:url( https://e.com/a.png )"]), 1)
        XCTAssertEqual(try count("span", ["style": "background-image: image-set(\"https://e.com/a.png\" 1x)"]), 1)
        XCTAssertEqual(try count("div", ["style": "background: url(\\68ttps://e.com/a.png)"]), 1)
        XCTAssertEqual(try count("div", ["style": "color: red; background: url(local.png)"]), 0)
    }
}

/// End to end in an offscreen WKWebView: the real preview.html shell renders
/// markdown and must show the banner for remote images however they are
/// nested (regression: README badges are images inside links inside a raw
/// HTML block).
@MainActor
final class RemoteImageBannerWebViewTests: XCTestCase {
    private final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded: XCTestExpectation?
        var posted: XCTestExpectation?
        var postedBodies: [Any] = []

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?.fulfill()
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            postedBodies.append(message.body)
            posted?.fulfill()
        }
    }

    private var harness: Harness!
    private var webView: WKWebView!

    /// Generous: a cold web content process on a CI runner can be slow.
    private let timeout: TimeInterval = 60

    /// An offscreen web view (never put in a window) with the strict shell,
    /// then optionally the remote-images variant.
    private func loadShell(allowRemoteImages: Bool = false) throws {
        let htmlURL = try XCTUnwrap(MdReaderResources.previewHTMLURL)
        harness = Harness()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(harness, name: "loadRemoteImages")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = harness
        // Like the app: the strict shell always loads first (which also
        // grants the web process read access to the resources folder), and
        // the opt-in variant replaces it.
        let loaded = expectation(description: "shell loaded")
        harness.loaded = loaded
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        wait(for: [loaded], timeout: timeout)
        if allowRemoteImages { try loadOptInShell() }
    }

    private func loadOptInShell() throws {
        let htmlURL = try XCTUnwrap(MdReaderResources.previewHTMLURL)
        let template = try String(contentsOf: htmlURL, encoding: .utf8)
        let html = try XCTUnwrap(MarkdownRenderBridge.previewShellHTML(
            template: template, allowRemoteImages: true))
        let reloaded = expectation(description: "opt-in shell loaded")
        harness.loaded = reloaded
        webView.loadHTMLString(html, baseURL: htmlURL)
        wait(for: [reloaded], timeout: timeout)
    }

    override func tearDown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "loadRemoteImages")
        webView = nil
        harness = nil
        super.tearDown()
    }

    private func evaluate(_ js: String) throws -> Any? {
        let done = expectation(description: "evaluate")
        var value: Any?
        var failure: Error?
        webView.evaluateJavaScript(js) { result, error in
            value = result
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        if let failure { throw failure }
        return value
    }

    /// Renders `markdown` and returns the remote image count, whether the
    /// banner is visible, and the scroll offset afterwards.
    @discardableResult
    private func render(
        _ markdown: String, scroll: RenderScroll = .keep
    ) throws -> (count: Int, banner: Bool, scrollY: Double) {
        let js = try XCTUnwrap(MarkdownRenderBridge.renderJS(for: markdown, scroll: scroll))
        let probe = """
            \(js);
            JSON.stringify({
              count: countRemoteImages(document.getElementById('previewmd-root')),
              banner: !!document.querySelector('.previewmd-remote-banner:not([hidden])'),
              scrollY: window.scrollY
            })
            """
        let json = try XCTUnwrap(try evaluate(probe) as? String)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return (try XCTUnwrap(object["count"] as? Int),
                try XCTUnwrap(object["banner"] as? Bool),
                try XCTUnwrap(object["scrollY"] as? Double))
    }

    private static let longText = (1...200).map { "Paragraph \($0)." }.joined(separator: "\n\n")

    private static let readmeBadges = """
        <div align="center">

        <img src="packaging/AppIcon.png" width="128" alt="icon">

        [![Latest release](https://img.shields.io/github/v/release/ychani/Preview-md?label=release)](https://github.com/ychani/Preview-md/releases/latest)
        ![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
        [![CI](https://github.com/ychani/Preview-md/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/ychani/Preview-md/actions/workflows/ci.yml)

        </div>
        """

    func testBannerForBadgesInsideLinksInsideHTMLBlock() throws {
        try loadShell()
        let result = try render(Self.readmeBadges)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.banner)
    }

    func testBannerForPictureSrcsetAndInlineStyle() throws {
        try loadShell()
        XCTAssertTrue(try render(
            "<picture><source srcset=\"https://e.com/a.webp\"><img src=\"a.png\" alt=\"a\"></picture>").banner)
        XCTAssertTrue(try render("<div style=\"background:url(https://e.com/bg.png)\">x</div>").banner)
        XCTAssertTrue(try render("<p><img src=\"https://e.com/raw.png\" alt=\"raw\"></p>").banner)
    }

    func testNoBannerWithoutRemoteImages() throws {
        try loadShell()
        let result = try render("![local](a.png) [link](https://example.com) `![x](https://e.com/x.png)`")
        XCTAssertEqual(result.count, 0)
        XCTAssertFalse(result.banner)
        // And it goes away again when the next render has none.
        XCTAssertTrue(try render(Self.readmeBadges).banner)
        XCTAssertFalse(try render("plain text").banner)
    }

    /// Re-rendering the same document keeps its scroll offset (e.g. a remote
    /// image typed in Split view while scrolled down): the banner must still
    /// be on screen.
    func testBannerVisibleWhenRenderedScrolledDown() throws {
        try loadShell()
        try render(Self.longText)
        _ = try evaluate("window.scrollTo(0, 3000); 0")
        let result = try render(Self.longText + "\n\n![x](https://e.com/x.png)")
        XCTAssertTrue(result.banner)
        XCTAssertEqual(result.scrollY, 3000, accuracy: 1)
        let top = try XCTUnwrap(try evaluate(
            "document.querySelector('.previewmd-remote-banner').getBoundingClientRect().top") as? Double)
        XCTAssertEqual(top, 0, accuracy: 1)
    }

    // MARK: Scroll position across renders

    func testSameDocumentKeepsScrollNewDocumentStartsAtTop() throws {
        try loadShell()
        try render(Self.longText, scroll: .top)
        _ = try evaluate("window.scrollTo(0, 3000); 0")
        // Same document re-rendered (typing, reload from disk).
        XCTAssertEqual(try render(Self.longText + "\n\nmore", scroll: .keep).scrollY, 3000, accuracy: 1)
        // A different document.
        XCTAssertEqual(try render(Self.readmeBadges + "\n\n" + Self.longText, scroll: .top).scrollY, 0)
    }

    func testOptInReloadRestoresScroll() throws {
        try loadShell()
        let doc = Self.readmeBadges + "\n\n" + Self.longText
        try render(doc, scroll: .top)
        _ = try evaluate("window.scrollTo(0, 2000); 0")
        let posted = expectation(description: "loadRemoteImages posted")
        harness.posted = posted
        _ = try evaluate("document.querySelector('.previewmd-remote-banner button').click(); 0")
        wait(for: [posted], timeout: timeout)
        let body = try XCTUnwrap(harness.postedBodies.first as? [String: Any])
        let scrollY = try XCTUnwrap((body["scrollY"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(scrollY, 2000, accuracy: 1)

        // What the app does: reload the opt-in shell, then render the same
        // document with the offset the tracker hands back.
        var tracker = PreviewScrollTracker()
        let url = URL(fileURLWithPath: "/notes/README.md")
        _ = tracker.scroll(forRenderOf: url)
        tracker.shellWillReload(document: url, scrollY: scrollY)
        try loadOptInShell()
        XCTAssertEqual(try evaluate("window.scrollY") as? Double, 0)
        let scroll = tracker.scroll(forRenderOf: url)
        XCTAssertEqual(scroll, .restore(scrollY))
        let result = try render(doc, scroll: scroll)
        XCTAssertFalse(result.banner)
        XCTAssertEqual(result.scrollY, 2000, accuracy: 1)
    }

    func testNoBannerOnceRemoteImagesAreAllowed() throws {
        try loadShell(allowRemoteImages: true)
        let result = try render(Self.readmeBadges)
        XCTAssertEqual(result.count, 3)
        XCTAssertFalse(result.banner)
    }
}
