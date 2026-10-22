import WebKit
import XCTest
@testable import MdReaderCore

/// read-aloud.js end to end in an offscreen WKWebView with the real
/// preview.html shell: text extraction, offset → highlight mapping (CSS
/// Custom Highlight API and the <mark> fallback), re-render handling,
/// click-to-seek, and staying inert without the message handler.
@MainActor
final class ReadAloudWebViewTests: XCTestCase {
    private final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded: XCTestExpectation?
        var messages: [ReadAloudBridge.Message] = []

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?.fulfill()
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            if let parsed = ReadAloudBridge.parseMessage(message.body) { messages.append(parsed) }
        }
    }

    private struct NoMessage: Error {}

    private var harness: Harness!
    private var webView: WKWebView!
    private var withHandler = true
    private let timeout: TimeInterval = 60

    private func loadShell(handler: Bool = true) throws {
        let htmlURL = try XCTUnwrap(MdReaderResources.previewHTMLURL)
        harness = Harness()
        withHandler = handler
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if handler {
            config.userContentController.add(harness, name: ReadAloudBridge.messageHandlerName)
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = harness
        let loaded = expectation(description: "shell loaded")
        harness.loaded = loaded
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        wait(for: [loaded], timeout: timeout)
        if handler {
            let ready = try waitForMessage { if case .ready = $0 { return true } else { return false } }
            XCTAssertEqual(ready, .ready(highlightMode: "css-highlight"),
                           "this WebKit should have the Highlight API")
        }
    }

    override func tearDown() {
        if withHandler {
            webView?.configuration.userContentController
                .removeScriptMessageHandler(forName: ReadAloudBridge.messageHandlerName)
        }
        webView = nil
        harness = nil
        super.tearDown()
    }

    @discardableResult
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

    private func render(_ markdown: String) throws {
        try evaluate(try XCTUnwrap(MarkdownRenderBridge.renderJS(for: markdown)) + "; 0")
    }

    /// Spins the run loop until a message matching `predicate` arrives (or
    /// is already queued); removes and returns it.
    @discardableResult
    private func waitForMessage(
        timeout: TimeInterval? = nil, _ predicate: (ReadAloudBridge.Message) -> Bool
    ) throws -> ReadAloudBridge.Message {
        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
        while Date() < deadline {
            if let i = harness.messages.firstIndex(where: predicate) {
                return harness.messages.remove(at: i)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("no matching message within the timeout; got \(harness.messages)")
        throw NoMessage()
    }

    private func requestText(_ request: Int = 1) throws -> (text: String, generation: Int) {
        let reply = try requestText(request, prefer: nil)
        XCTAssertEqual(reply.startOffset, 0, "the app's own command starts at the top")
        return (reply.text, reply.generation)
    }

    private func requestText(
        _ request: Int, prefer: ReadAloudBridge.StartPreference?
    ) throws -> (text: String, generation: Int, startOffset: Int) {
        try evaluate(ReadAloudBridge.requestTextJS(request: request, prefer: prefer))
        let message = try waitForMessage {
            if case .text(_, _, request, _) = $0 { return true } else { return false }
        }
        guard case .text(let text, let generation, _, let startOffset) = message else { throw NoMessage() }
        return (text, generation, startOffset)
    }

    /// The text painted by a highlight, one string per range (CSS mode) or
    /// per <mark> (fallback).
    private func painted(_ name: String) throws -> [String] {
        let json = try XCTUnwrap(try evaluate("""
            JSON.stringify(PreviewMDReadAloud.highlightMode === 'mark'
              ? Array.from(document.querySelectorAll('mark.\(name)')).map(function (m) { return m.textContent; })
              : (CSS.highlights.get('\(name)') ? Array.from(CSS.highlights.get('\(name)')).map(function (r) { return r.toString(); }) : []))
            """) as? String)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String])
    }

    private func range(of needle: String, in text: String) throws -> Range<Int> {
        let r = (text as NSString).range(of: needle)
        XCTAssertNotEqual(r.location, NSNotFound, "\(needle) not in text")
        return r.location..<(r.location + r.length)
    }

    private func rootHTML() throws -> String {
        try XCTUnwrap(try evaluate("document.getElementById('previewmd-root').innerHTML") as? String)
    }

    private static let sample = """
        # Title

        Para with **bold** and `code` and [link](https://example.com).

        - one
        - two

        ```swift
        let x = 1
        ```

        | A | B |
        |---|---|
        | c | d |

        ![alt](img.png)

        > Quote line
        """

    // MARK: Extraction

    func testExtractsReadableTextWithBlockSeparators() throws {
        try loadShell()
        try render(Self.sample)
        let (text, _) = try requestText()
        XCTAssertEqual(text, "Title\n\nPara with bold and code and link.\n\none\n\ntwo\n\nA\nB\n\nc\nd\n\nQuote line\n\n")
    }

    func testSkipsFrontMatterMermaidHiddenAndClosedDetails() throws {
        try loadShell()
        try render("""
            ---
            title: Secret
            ---
            Visible.

            ```mermaid
            graph TD; A-->B
            ```

            <details><summary>More</summary>

            Hidden body.

            </details>

            <p hidden>Nope</p><p aria-hidden="true">Nope</p>

            End.
            """)
        let (text, _) = try requestText()
        XCTAssertEqual(text, "Visible.\n\nMore\n\nEnd.\n\n")
    }

    func testNoContentAndInertBridgeCalls() throws {
        try loadShell()
        try render("```\nonly code\n```")
        try evaluate(ReadAloudBridge.requestTextJS(request: 9))
        let message = try waitForMessage { if case .error = $0 { return true } else { return false } }
        XCTAssertEqual(message, .error(code: "noContent", request: 9))
    }

    // MARK: Highlighting

    func testHighlightsWordAndSentenceWithoutTouchingTheDOM() throws {
        try loadShell()
        try render(Self.sample)
        let before = try rootHTML()
        let (text, generation) = try requestText()
        try evaluate(ReadAloudBridge.activateJS(generation: generation))
        let sentence = try range(of: "Para with bold and code and link.", in: text)
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "bold", in: text), sentence: sentence))
        XCTAssertEqual(try painted("univocal-word"), ["bold"])
        XCTAssertEqual(try painted("univocal-sentence").joined(), "Para with bold and code and link.")
        XCTAssertEqual(try rootHTML(), before, "the Highlight API must not change the DOM")

        // A word in a table cell.
        let cell = try range(of: "c\nd", in: text).lowerBound + 2
        try evaluate(ReadAloudBridge.applyJS(word: cell..<(cell + 1), sentence: nil))
        XCTAssertEqual(try painted("univocal-word"), ["d"])
        XCTAssertEqual(try painted("univocal-sentence"), [])

        try evaluate(ReadAloudBridge.deactivateJS)
        XCTAssertEqual(try painted("univocal-word"), [])
    }

    func testUnicodeOffsetsAreUTF16() throws {
        try loadShell()
        try render("👍🏽 Ünïcode cafe\u{301} 漢字 **te**xt.")
        let (text, generation) = try requestText()
        XCTAssertEqual(text, "👍🏽 Ünïcode cafe\u{301} 漢字 text.\n\n")
        try evaluate(ReadAloudBridge.activateJS(generation: generation))
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "漢字", in: text), sentence: nil))
        XCTAssertEqual(try painted("univocal-word"), ["漢字"])
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "cafe\u{301}", in: text), sentence: nil))
        XCTAssertEqual(try painted("univocal-word"), ["cafe\u{301}"])
        // Crosses </strong>: two ranges.
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "text", in: text), sentence: nil))
        XCTAssertEqual(try painted("univocal-word"), ["te", "xt"])
    }

    func testMarkFallbackRestoresTheDocumentExactly() throws {
        try loadShell()
        try render("Un**believ**able things happen. Second sentence here.")
        let before = try rootHTML()
        let textContent = "document.getElementById('previewmd-root').textContent"
        let beforeText = try XCTUnwrap(try evaluate(textContent) as? String)
        let (text, generation) = try requestText()
        try evaluate("PreviewMDReadAloud.forceMarkMode(); 0")
        XCTAssertEqual(try evaluate("PreviewMDReadAloud.highlightMode") as? String, "mark")
        try evaluate(ReadAloudBridge.activateJS(generation: generation))

        let first = try range(of: "Unbelievable things happen.", in: text)
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "Unbelievable", in: text), sentence: first))
        XCTAssertEqual(try painted("univocal-word"), ["Un", "believ", "able"])
        XCTAssertEqual(try painted("univocal-sentence").joined(), "Unbelievable things happen.")
        XCTAssertEqual(try evaluate(textContent) as? String, beforeText)

        // Moving on re-maps through the original nodes.
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "things", in: text), sentence: first))
        XCTAssertEqual(try painted("univocal-word"), ["things"])
        let second = try range(of: "Second sentence here.", in: text)
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "here", in: text), sentence: second))
        XCTAssertEqual(try painted("univocal-word"), ["here"])
        XCTAssertEqual(try painted("univocal-sentence").joined(), "Second sentence here.")

        // Extraction while marks are on screen sees the same text.
        XCTAssertEqual(try requestText(2).text, text)

        try evaluate(ReadAloudBridge.deactivateJS)
        XCTAssertEqual(try rootHTML(), before)
    }

    // MARK: Re-render

    func testSameTextReRenderRepaints() throws {
        try loadShell()
        try render(Self.sample)
        let (text, generation) = try requestText()
        try evaluate(ReadAloudBridge.activateJS(generation: generation))
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "two", in: text), sentence: nil))
        try render(Self.sample)
        XCTAssertEqual(try painted("univocal-word"), ["two"])
        XCTAssertFalse(harness.messages.contains { if case .textChanged = $0 { return true } else { return false } })
    }

    func testEditPostsTextChangedAtTheRemappedSentence() throws {
        try loadShell()
        let original = "First paragraph here.\n\nSecond paragraph. Third sentence."
        try render(original)
        let (text, generation) = try requestText()
        try evaluate(ReadAloudBridge.activateJS(generation: generation))
        let third = try range(of: "Third sentence.", in: text)
        try evaluate(ReadAloudBridge.applyJS(word: third.lowerBound..<(third.lowerBound + 5), sentence: third))

        // Edit before the current sentence, twice in quick succession (typing).
        try render("First paragraph, edited, here.\n\nSecond paragraph. Third sentence.")
        try render("First paragraph, now edited, here.\n\nSecond paragraph. Third sentence.")
        XCTAssertEqual(try painted("univocal-word"), [], "nothing painted on stale offsets")
        let message = try waitForMessage(timeout: 10) {
            if case .textChanged = $0 { return true } else { return false }
        }
        guard case .textChanged(let newText, let startOffset, let newGeneration) = message else { return }
        XCTAssertEqual(newText, "First paragraph, now edited, here.\n\nSecond paragraph. Third sentence.\n\n")
        XCTAssertEqual((newText as NSString).substring(from: startOffset), "Third sentence.\n\n")
        XCTAssertEqual(harness.messages.filter { if case .textChanged = $0 { return true } else { return false } }.count,
                       0, "debounced to one message")

        // Events from the old session are ignored until Swift restarts.
        try evaluate(ReadAloudBridge.applyJS(word: 0..<5, sentence: nil))
        XCTAssertEqual(try painted("univocal-word"), [])
        try evaluate(ReadAloudBridge.activateJS(generation: newGeneration))
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "now", in: newText), sentence: nil))
        XCTAssertEqual(try painted("univocal-word"), ["now"])
    }

    func testReattachAfterShellReload() throws {
        try loadShell()
        let text = "Hello there. General Kenobi.\n\n"
        // A fresh page: the session's text arrives before the document renders.
        let kenobi = try range(of: "Kenobi", in: text)
        try evaluate(try XCTUnwrap(ReadAloudBridge.reattachJS(text: text, word: kenobi, sentence: nil)))
        try render("Hello there. General Kenobi.")
        XCTAssertEqual(try painted("univocal-word"), ["Kenobi"])

        // Re-attach with text the page does not show: it asks for a restart.
        try evaluate(try XCTUnwrap(ReadAloudBridge.reattachJS(text: "Something else.\n\n", word: 0..<9, sentence: nil)))
        let message = try waitForMessage(timeout: 10) {
            if case .textChanged = $0 { return true } else { return false }
        }
        guard case .textChanged(let newText, _, _) = message else { return }
        XCTAssertEqual(newText, text)
    }

    // MARK: Click-to-seek

    func testClickOnTextPostsSeekOffset() throws {
        try loadShell()
        try render("Alpha beta gamma.\n\nDelta [epsilon](#nowhere) zeta.")
        let (text, generation) = try requestText()
        try evaluate(ReadAloudBridge.activateJS(generation: generation))
        try evaluate(ReadAloudBridge.applyJS(word: 0..<5, sentence: nil))

        func click(_ word: String) throws {
            let r = try range(of: word, in: text)
            // Middle of the word's first character, found through the highlight.
            try evaluate(ReadAloudBridge.applyJS(word: r, sentence: nil))
            try evaluate("""
                (function () {
                  var h = CSS.highlights.get('univocal-word');
                  var rect = Array.from(h)[0].getBoundingClientRect();
                  var x = rect.left + 2, y = rect.top + rect.height / 2;
                  var el = document.elementFromPoint(x, y);
                  el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true,
                    clientX: x, clientY: y, button: 0 }));
                  return 0;
                })()
                """)
        }
        let gamma = try range(of: "gamma", in: text)
        try click("gamma")
        let message = try waitForMessage(timeout: 10) { if case .seek = $0 { return true } else { return false } }
        guard case .seek(let offset) = message else { return }
        XCTAssertTrue(gamma.lowerBound...gamma.upperBound ~= offset, "\(offset) not in \(gamma)")

        // Links keep their meaning.
        try click("epsilon")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(harness.messages.contains { if case .seek = $0 { return true } else { return false } })

        // Not while inactive.
        try evaluate(ReadAloudBridge.deactivateJS)
        try evaluate("""
            (function () {
              var p = document.querySelector('#previewmd-root p'); var r = p.getBoundingClientRect();
              p.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: r.left + 3, clientY: r.top + 5, button: 0 }));
              return 0;
            })()
            """)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(harness.messages.contains { if case .seek = $0 { return true } else { return false } })
    }

    func testClickInsideFallbackMarkMapsThroughThePiece() throws {
        try loadShell()
        try render("Alpha beta gamma delta.")
        let (text, generation) = try requestText()
        try evaluate("PreviewMDReadAloud.forceMarkMode(); 0")
        try evaluate(ReadAloudBridge.activateJS(generation: generation))
        let gamma = try range(of: "gamma", in: text)
        try evaluate(ReadAloudBridge.applyJS(word: gamma, sentence: 0..<text.utf16.count))
        try evaluate("""
            (function () {
              var m = document.querySelector('mark.univocal-word');
              var rect = m.getBoundingClientRect();
              var x = rect.right - 2, y = rect.top + rect.height / 2;
              document.elementFromPoint(x, y).dispatchEvent(new MouseEvent('click', { bubbles: true,
                cancelable: true, clientX: x, clientY: y, button: 0 }));
              return 0;
            })()
            """)
        let message = try waitForMessage(timeout: 10) { if case .seek = $0 { return true } else { return false } }
        guard case .seek(let offset) = message else { return }
        XCTAssertTrue(gamma.lowerBound...gamma.upperBound ~= offset, "\(offset) not in \(gamma)")
    }

    // MARK: Scroll-follow

    func testScrollFollowAndManualScrollSuspension() throws {
        try loadShell()
        let paragraphs = (1...120).map { "Paragraph number \($0) of the test." }
        try render(paragraphs.joined(separator: "\n\n"))
        let (text, generation) = try requestText()
        try evaluate(ReadAloudBridge.activateJS(generation: generation))
        func scrollY() throws -> Double { try XCTUnwrap(try evaluate("window.scrollY") as? Double) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(1.2)) }

        // A word inside the comfort band: no scroll.
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "number 3 ", in: text), sentence: nil))
        settle()
        XCTAssertEqual(try scrollY(), 0)

        // Far below: follows.
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "number 60 ", in: text), sentence: nil))
        settle()
        let followed = try scrollY()
        XCTAssertGreaterThan(followed, 0)
        let centre = try XCTUnwrap(try evaluate("""
            (function () { var r = Array.from(CSS.highlights.get('univocal-word'))[0].getBoundingClientRect();
              return (r.top + r.height / 2) / window.innerHeight; })()
            """) as? Double)
        XCTAssertEqual(centre, 0.4, accuracy: 0.1)

        // The user scrolls: following pauses.
        try evaluate("window.dispatchEvent(new WheelEvent('wheel', { deltaY: 10 })); 0")
        try evaluate(ReadAloudBridge.applyJS(word: try range(of: "number 110 ", in: text), sentence: nil))
        settle()
        XCTAssertEqual(try scrollY(), followed, accuracy: 1)
    }

    // MARK: Hotkey start offset (SPEC §16.12)

    /// Selects `needle` (or `length` characters from its start) in the first
    /// document text node that contains it.
    private func select(_ needle: String, length: Int? = nil) throws {
        let literal = try XCTUnwrap(MarkdownRenderBridge.jsonArrayLiteral(needle))
        try evaluate("""
            (function () {
              var needle = (\(literal))[0];
              var w = document.createTreeWalker(document.getElementById('previewmd-root'), NodeFilter.SHOW_TEXT);
              for (var n = w.nextNode(); n; n = w.nextNode()) {
                var i = n.data.indexOf(needle);
                if (i >= 0) {
                  var end = Math.min(n.data.length, i + \(length ?? needle.utf16.count));
                  window.getSelection().setBaseAndExtent(n, i, n, end);
                  return 0;
                }
              }
              throw new Error('needle not found');
            })()
            """)
    }

    func testHotkeyStartsAtTheSelection() throws {
        try loadShell()
        try render("First paragraph here.\n\nSecond **para**graph with words.\n\nThird one.")
        try select("graph with")
        let reply = try requestText(1, prefer: .selection)
        XCTAssertEqual(reply.text, "First paragraph here.\n\nSecond paragraph with words.\n\nThird one.\n\n")
        XCTAssertEqual(reply.startOffset, try range(of: "graph with", in: reply.text).lowerBound)

        // `document` ignores the selection: the top block is visible.
        XCTAssertEqual(try requestText(2, prefer: .document).startOffset, 0)
    }

    func testHotkeySelectionOnElementBoundariesAndSkippedBlocks() throws {
        try loadShell()
        try render("Intro text.\n\n```\nlet code = 1\n```\n\nAfter the code.\n\n- item one\n- item two")
        // A selection that starts inside a code block (not read) starts at
        // the next text that is.
        try evaluate("""
            (function () {
              var pre = document.querySelector('#previewmd-root pre');
              var t = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT).nextNode();
              window.getSelection().setBaseAndExtent(t, 0, t, 1);
              return 0;
            })()
            """)
        var reply = try requestText(1, prefer: .selection)
        XCTAssertEqual(reply.startOffset, try range(of: "After the code.", in: reply.text).lowerBound)

        // A selection anchored on an element (the second list item).
        try evaluate("""
            (function () {
              var li = document.querySelectorAll('#previewmd-root li')[1];
              var r = document.createRange(); r.selectNodeContents(li);
              var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
              return 0;
            })()
            """)
        reply = try requestText(2, prefer: .selection)
        XCTAssertEqual(reply.startOffset, try range(of: "item two", in: reply.text).lowerBound)
    }

    func testHotkeyWithoutSelectionStartsAtTheFirstFullyVisibleBlock() throws {
        try loadShell()
        let paragraphs = (1...80).map { "Paragraph number \($0) of the test." }
        try render(paragraphs.joined(separator: "\n\n"))
        XCTAssertEqual(try requestText(1, prefer: .selection).startOffset, 0)

        // Scroll so that a paragraph is cut off at the top.
        let expected = try XCTUnwrap(try evaluate("""
            (function () {
              var ps = document.querySelectorAll('#previewmd-root p');
              var r = ps[30].getBoundingClientRect();
              window.scrollTo(0, window.scrollY + r.top + r.height / 2);
              for (var i = 0; i < ps.length; i++) {
                if (ps[i].getBoundingClientRect().top >= 0) return ps[i].textContent;
              }
              return null;
            })()
            """) as? String)
        XCTAssertEqual(expected, "Paragraph number 32 of the test.")
        let reply = try requestText(2, prefer: .selection)
        XCTAssertEqual(reply.startOffset, try range(of: expected, in: reply.text).lowerBound)

        // A selection elsewhere wins for `selection`, not for `document`.
        try select("number 40 ")
        XCTAssertEqual(try requestText(3, prefer: .selection).startOffset,
                       try range(of: "number 40 ", in: reply.text).lowerBound)
        XCTAssertEqual(try requestText(4, prefer: .document).startOffset, reply.startOffset)
    }

    func testHotkeySelectionInsideFallbackMarks() throws {
        try loadShell()
        try render("Alpha beta gamma delta. Epsilon zeta.")
        let (text, generation) = try requestText()
        try evaluate("PreviewMDReadAloud.forceMarkMode(); 0")
        try evaluate(ReadAloudBridge.activateJS(generation: generation))
        let gamma = try range(of: "gamma", in: text)
        try evaluate(ReadAloudBridge.applyJS(word: gamma, sentence: 0..<text.utf16.count))
        // Select inside the <mark> piece: "mma".
        try evaluate("""
            (function () {
              var t = document.querySelector('mark.univocal-word').firstChild;
              window.getSelection().setBaseAndExtent(t, 2, t, 5);
              return 0;
            })()
            """)
        let reply = try requestText(2, prefer: .selection)
        XCTAssertEqual(reply.text, text)
        XCTAssertEqual(reply.startOffset, gamma.lowerBound + 2)
        XCTAssertEqual(try painted("univocal-word"), ["gamma"], "the session keeps its highlight")
    }

    // MARK: Inert without the handler

    func testInertWithoutMessageHandler() throws {
        try loadShell(handler: false)
        try render(Self.sample)
        XCTAssertEqual(try evaluate("typeof PreviewMDReadAloud") as? String, "undefined")
        // Swift's calls are guarded and do nothing.
        XCTAssertEqual(try evaluate(ReadAloudBridge.applyJS(word: 0..<5, sentence: nil)) as? Bool, false)
        XCTAssertEqual(try evaluate("CSS.highlights.size") as? Int, 0)
    }
}
