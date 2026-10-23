import MdReaderCore
import UnivocalClient
import UnivocalMock
import WebKit
import XCTest
@testable import MdReader

/// Highlights across sessions, end to end: the real controller, SDK and
/// preview shell (offscreen) against an in-process mock with a manual clock.
/// After a session ends, the next one on the same document must show only
/// its own current word and sentence — nothing left over from the first.
@MainActor
final class ReadAloudRepaintTests: XCTestCase {
    private final class Backend: ReadAloudBackend, @unchecked Sendable {
        let client: UnivocalClient
        init(connectDir: URL) {
            var config = UnivocalConfiguration(client: UnivocalClientIdentity(
                id: "com.narnarlabs.previewmd", name: "PreviewMD (tests)", version: "test"))
            config.connectDirectory = connectDir
            config.tokenStore = InMemoryTokenStore()
            config.hotkeyTarget = true
            client = UnivocalClient(configuration: config)
        }
        func availability() -> UnivocalAvailability {
            .installed(appURL: URL(fileURLWithPath: "/Applications"), running: true)
        }
        func connectionStates() -> AsyncStream<UnivocalConnectionState> { client.stateUpdates() }
        func startReading(_ request: ReadRequest) async throws -> any ReadAloudSession {
            try await client.read(request)
        }
        func readRequests() -> AsyncStream<UnivocalReadRequest> { client.readRequests() }
        func accept(_ request: UnivocalReadRequest) async throws { try await client.accept(request) }
        func decline(_ request: UnivocalReadRequest, reason: UnivocalDeclineReason, detail: String?) async throws {
            try await client.decline(request, reason: reason, detail: detail)
        }
        func startReading(_ request: ReadRequest, answering hotkey: UnivocalReadRequest) async throws
            -> any ReadAloudSession {
            try await client.read(request, answering: hotkey)
        }
        func connectIfAuthorized() async throws -> Bool { try await client.connectIfAuthorized() != nil }
        func connectForWake(requestId: String) async throws { _ = try await client.connectForWake(requestId: requestId) }
        func serverAppearances() -> AsyncStream<UnivocalDiscovery> {
            AsyncStream { _ in }
        }
    }

    private final class Relay: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded = false
        weak var controller: ReadAloudController?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let parsed = ReadAloudBridge.parseMessage(message.body) else { return }
            MainActor.assumeIsolated { controller?.handle(parsed, from: message.webView) }
        }
    }

    private struct Timeout: Error, CustomStringConvertible { let description: String }

    private static let markdown = """
        # Progress update

        Our research continues this week. The team met twice.

        | Area | Status | Owner |
        |---|---|---|
        | Docs | Done | Ana |

        Final words close the note.
        """

    private var dir: URL!
    private var server: MockServer!
    private var backend: Backend!
    private var controller: ReadAloudController!
    private var relay: Relay!
    private var webView: WKWebView!
    private var window: NSWindow!
    /// A second window's preview of the same document (all windows share
    /// one AppState, so one controller drives every page).
    private var second: (webView: WKWebView, window: NSWindow, relay: Relay)?

    override func setUpWithError() throws {
        let name = "rp-" + UUID().uuidString.prefix(6).lowercased()
        dir = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var behaviour = MockBehaviour()
        behaviour.wordsPerMinute = 0          // manual clock: words move on advance()
        behaviour.loadingDelay = .zero
        behaviour.answerDeadline = .seconds(5)
        behaviour.acceptedDeadline = .seconds(10)
        behaviour.wakeOpener = { _ in false }
        behaviour.frontmost = MockFrontmost(pid: getpid(), bundleId: "com.narnarlabs.previewmd")
        let server = MockServer(directory: dir, behaviour: behaviour)
        self.server = server
        try run { try await server.start() }

        backend = Backend(connectDir: dir)
        controller = ReadAloudController(backend: backend, openURL: { _ in })
        controller.hotkeySource = { .preview }
        controller.startHotkeyIntegration()
        relay = Relay()
        relay.controller = controller

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(relay, name: ReadAloudBridge.messageHandlerName)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: config)
        webView.navigationDelegate = relay
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 500),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        let html = try XCTUnwrap(MdReaderResources.previewHTMLURL)
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        try spin("shell loaded") { self.relay.loaded && self.controller.highlightMode != nil }
        try evaluate(try XCTUnwrap(MarkdownRenderBridge.renderJS(for: Self.markdown)) + "; 0")
    }

    override func tearDownWithError() throws {
        controller?.stop()
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: ReadAloudBridge.messageHandlerName)
        window?.orderOut(nil)
        if let second {
            second.webView.configuration.userContentController
                .removeScriptMessageHandler(forName: ReadAloudBridge.messageHandlerName)
            second.window.orderOut(nil)
        }
        let client = backend?.client, server = server
        try? run { await client?.disconnect(); await server?.stop() }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func testSecondInAppSessionShowsOnlyItsOwnWord() throws {
        try readFirstSessionToTheEnd()
        controller.toggle()
        try checkSecondSession()
    }

    func testSecondHotkeySessionShowsOnlyItsOwnWord() throws {
        try readFirstSessionToTheEnd()
        let server = self.server!
        let outcome = try run { await server.simulateHotkey(prefer: .document) }
        guard case .routed = outcome else { return XCTFail("hotkey not routed: \(outcome)") }
        try checkSecondSession()
    }

    /// Session 1 moves from window A's preview to window B's (B's page
    /// loads mid-read); A must be cleared then, both when it ends, and the
    /// next session paints only B's current word.
    func testHighlightsLiveOnOnePageAcrossWindows() throws {
        controller.toggle()
        try spin("session 1 playing") { self.controller.status == .playing }
        for _ in 0..<3 {
            let server = self.server!
            try run { await server.advance(words: 1) }
        }
        try spin("A painted") { !((try? self.painted("univocal-word")) ?? []).isEmpty }

        let b = try openSecondPage()
        let server = self.server!
        try run { await server.advance(words: 1) }
        try spin("B painted") { !((try? self.painted("univocal-word", on: b)) ?? []).isEmpty }
        XCTAssertEqual(try painted("univocal-word"), [], "window A kept a word after the reading moved to B")
        XCTAssertEqual(try painted("univocal-sentence"), [], "window A kept a sentence after the reading moved to B")

        var steps = 0
        while controller.status != .idle && steps < 200 {
            try run { await server.advance(words: 1) }
            try spin("tick", 2) { true }
            steps += 1
        }
        try spinFor(0.2)
        for page in [webView!, b] {
            XCTAssertEqual(try painted("univocal-word", on: page), [], "a word survived `ended`")
            XCTAssertEqual(try painted("univocal-sentence", on: page), [], "a sentence survived `ended`")
        }

        let outcome = try run { await server.simulateHotkey(prefer: .document) }
        guard case .routed = outcome else { return XCTFail("hotkey not routed: \(outcome)") }
        try checkSecondSession(on: b)
        XCTAssertEqual(try painted("univocal-word"), [], "session 2 painted in the other window too")
    }

    // MARK: - Steps

    /// Session 1 from the top, word by word through the heading and the
    /// table, until Univocal reports `finished`.
    private func readFirstSessionToTheEnd() throws {
        controller.toggle()
        try spin("session 1 playing") { self.controller.status == .playing }
        var steps = 0
        while controller.status != .idle {
            let server = self.server!
            try run { await server.advance(words: 1) }
            try spin("word painted", 2) { true }
            steps += 1
            XCTAssertLessThan(steps, 200, "session 1 never finished")
            if steps >= 200 { break }
        }
        try spinFor(0.2)
        XCTAssertEqual(try painted("univocal-word"), [], "session 1 left a word highlight after `ended`")
        XCTAssertEqual(try painted("univocal-sentence"), [], "session 1 left a sentence highlight after `ended`")
    }

    /// Session 2: after each word event exactly one word is painted — the
    /// controller's current word — and the registry holds at most our two.
    private func checkSecondSession(on page: WKWebView? = nil) throws {
        try spin("session 2 playing") { self.controller.status == .playing }
        let text = try XCTUnwrap(controller.sessionText)
        for _ in 0..<6 {
            let server = self.server!
            try run { await server.advance(words: 1) }
            try spin("current word painted") {
                guard let word = self.controller.currentWord else { return false }
                return (try? self.painted("univocal-word", on: page)) == [Self.slice(text, word)]
            }
            let word = try XCTUnwrap(controller.currentWord)
            XCTAssertEqual(try painted("univocal-word", on: page), [Self.slice(text, word)])
            let registered = try XCTUnwrap(try evaluate("""
                JSON.stringify(Array.from(CSS.highlights.keys()))
                """, on: page) as? String)
            XCTAssertTrue(["[]", "[\"univocal-sentence\"]", "[\"univocal-word\"]",
                           "[\"univocal-sentence\",\"univocal-word\"]",
                           "[\"univocal-word\",\"univocal-sentence\"]"].contains(registered),
                          "unexpected highlight registrations: \(registered)")
            let sentence = try painted("univocal-sentence", on: page).joined()
            if let s = controller.currentSentence {
                XCTAssertTrue(Self.slice(text, s).contains(sentence.replacingOccurrences(of: "\n", with: "")) || sentence.isEmpty,
                              "sentence highlight outside the current sentence: \(sentence.debugDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func openSecondPage() throws -> WKWebView {
        let relay = Relay()
        relay.controller = controller
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(relay, name: ReadAloudBridge.messageHandlerName)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: config)
        page.navigationDelegate = relay
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -3000, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = page
        second = (page, window, relay)
        // Render as soon as the shell is up, before the page's `ready`
        // reaches the controller's re-attach (MarkdownPreviewView does the same).
        let html = try XCTUnwrap(MdReaderResources.previewHTMLURL)
        page.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        try spin("second shell loaded") { relay.loaded }
        try evaluate(try XCTUnwrap(MarkdownRenderBridge.renderJS(for: Self.markdown)) + "; 0", on: page)
        return page
    }

    private static func slice(_ text: String, _ r: Range<Int>) -> String {
        (text as NSString).substring(with: NSRange(location: r.lowerBound, length: r.count))
    }

    private func painted(_ name: String, on page: WKWebView? = nil) throws -> [String] {
        let json = try evaluate("""
            JSON.stringify(PreviewMDReadAloud.highlightMode === 'mark'
              ? Array.from(document.querySelectorAll('mark.\(name)')).map(function (m) { return m.textContent; })
              : (CSS.highlights.get('\(name)') ? Array.from(CSS.highlights.get('\(name)')).map(function (r) { return r.toString(); }) : []))
            """, on: page) as? String ?? "[]"
        return (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String]) ?? []
    }

    @discardableResult
    private func evaluate(_ js: String, on page: WKWebView? = nil) throws -> Any? {
        var result: Result<Any?, Error>?
        (page ?? webView).evaluateJavaScript(js) { value, error in
            result = error.map { .failure($0) } ?? .success(value)
        }
        try spin("evaluate") { result != nil }
        return try result!.get()
    }

    private func spinFor(_ seconds: TimeInterval) throws {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func spin(_ what: String, _ seconds: TimeInterval = 10, _ done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { throw Timeout(description: "timed out waiting for \(what)") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Runs async work to completion while the main run loop keeps turning
    /// (WebKit and the controller live on it).
    @discardableResult
    private func run<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task.detached {
            do { let v = try await work(); await MainActor.run { result = .success(v) } }
            catch { await MainActor.run { result = .failure(error) } }
        }
        try spin("async work", 15) { result != nil }
        return try result!.get()
    }
}
