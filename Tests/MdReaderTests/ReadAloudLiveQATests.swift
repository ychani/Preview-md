import MdReaderCore
import UnivocalClient
import WebKit
import XCTest
@testable import MdReader

/// Manual-QA harness, skipped unless `UNIVOCAL_QA_DIR` is set: the real
/// controller, the real SDK and the real preview shell (in an offscreen
/// window), against a separately running `univocal-mock serve`. It writes a
/// snapshot PNG and a log line per step to `UNIVOCAL_QA_OUT` so a person can
/// watch the highlight travel through the document.
///
///     univocal-mock serve --dir "$D" --consent prompt < ctl   # ctl: a file `tail -f`'d into stdin
///     UNIVOCAL_QA_DIR="$D" UNIVOCAL_QA_OUT=/path/out UNIVOCAL_QA_DOC=doc.md \
///       UNIVOCAL_QA_MOCKCTL=ctl swift test --filter ReadAloudLiveQATests
///
/// With `UNIVOCAL_QA_MOCKCTL` the harness answers the consent prompt by
/// appending `y` to that file. Tokens live in memory only; the real
/// Keychain is never touched.
///
/// `UNIVOCAL_QA_HOTKEY=1` (with `UNIVOCAL_QA_MOCKCTL`) also runs the hotkey
/// scenario (SPEC §16): the harness connects as a `hotkey-target`, selects a
/// paragraph, then drives the mock console through the ctl file —
/// `frontmost <bundle-id> <this pid>` and `hotkey` — and checks that the
/// reading starts at the selection, that a second `hotkey` pauses (Univocal
/// toggles; the highlight stays put) and a third resumes. PreviewMD has no
/// pause control of its own: Univocal's pill and hotkey are the controls.
@MainActor
final class ReadAloudLiveQATests: XCTestCase {
    private final class Backend: ReadAloudBackend, @unchecked Sendable {
        let client: UnivocalClient
        init(connectDir: URL, hotkeyTarget: Bool = false) {
            var config = UnivocalConfiguration(client: UnivocalClientIdentity(
                id: "com.narnarlabs.previewmd", name: "PreviewMD (QA)", version: "qa"))
            config.connectDirectory = connectDir
            config.tokenStore = InMemoryTokenStore()
            config.hotkeyTarget = hotkeyTarget
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
            UnivocalLocator.serverAppearances(configuration: client.configuration)
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

    private var webView: WKWebView!
    private var log: [String] = []
    private var shot = 0

    func testReadThroughDocumentAgainstMock() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["UNIVOCAL_QA_DIR"], let out = env["UNIVOCAL_QA_OUT"] else {
            throw XCTSkip("set UNIVOCAL_QA_DIR and UNIVOCAL_QA_OUT to run the live QA harness")
        }
        let outURL = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let markdown = try env["UNIVOCAL_QA_DOC"].map { try String(contentsOfFile: $0) }
            ?? "# QA\n\nOne short sentence. Another one follows it.\n"

        let relay = Relay()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(relay, name: ReadAloudBridge.messageHandlerName)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 300), configuration: config)
        webView.navigationDelegate = relay
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 760, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            config.userContentController.removeScriptMessageHandler(forName: ReadAloudBridge.messageHandlerName)
        }

        let controller = ReadAloudController(backend: Backend(connectDir: URL(fileURLWithPath: dir)),
                                             openURL: { _ in })
        relay.controller = controller
        controller.documentTitle = { "qa.md" }

        let html = try XCTUnwrap(MdReaderResources.previewHTMLURL)
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        try spin(until: "shell loaded", 30) { relay.loaded && controller.highlightMode != nil }
        try evaluate(try XCTUnwrap(MarkdownRenderBridge.renderJS(for: markdown)) + "; 0")
        note("highlight mode: \(controller.highlightMode ?? "?")")

        controller.readAloud()
        try spin(until: "consent or playing", 30) {
            controller.status == .awaitingConsent || controller.status == .playing
        }
        if controller.status == .awaitingConsent {
            note("status: awaitingConsent")
            try snapshot(outURL, "consent")
            if let ctl = env["UNIVOCAL_QA_MOCKCTL"] {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: ctl))
                handle.seekToEndOfFile()
                handle.write(Data("y\n".utf8))
                try handle.close()
            }
        }
        try spin(until: "playing", 150) { controller.status == .playing }

        var words: [String] = []
        var scrolls: [Double] = []
        for i in 0..<10 {
            spinFor(1.2)
            let word = try painted("univocal-word").joined()
            let sentence = try painted("univocal-sentence").joined()
            let y = (try evaluate("window.scrollY") as? Double) ?? -1
            words.append(word); scrolls.append(y)
            note("t\(i) status=\(controller.status) word=\(word.debugDescription) scrollY=\(y) sentence=\(sentence.prefix(60).debugDescription)")
            try snapshot(outURL, "read-\(i)")
            if i == 6 {
                // An edit mid-read: the page re-renders and reading resumes
                // at the current sentence of the new text.
                try evaluate(try XCTUnwrap(MarkdownRenderBridge.renderJS(
                    for: "> Inserted note at the top.\n\n" + markdown)) + "; 0")
                note("re-rendered with an inserted paragraph")
            }
        }
        controller.stop()
        try spin(until: "idle", 10) { controller.status == .idle }
        spinFor(0.3)
        XCTAssertEqual(try painted("univocal-word"), [], "highlights left after stop")
        try snapshot(outURL, "stopped")
        note("stopped; highlights cleared")

        let distinct = Set(words.filter { !$0.isEmpty })
        XCTAssertGreaterThanOrEqual(distinct.count, 6, "highlight did not travel: \(words)")
        XCTAssertGreaterThan(scrolls.max() ?? 0, 0, "never scrolled to follow the reading")
        try log.joined(separator: "\n").write(to: outURL.appendingPathComponent("qa.log"),
                                              atomically: true, encoding: .utf8)
    }

    func testHotkeyAgainstMock() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["UNIVOCAL_QA_HOTKEY"] == "1", let dir = env["UNIVOCAL_QA_DIR"],
              let out = env["UNIVOCAL_QA_OUT"], let ctl = env["UNIVOCAL_QA_MOCKCTL"] else {
            throw XCTSkip("set UNIVOCAL_QA_HOTKEY=1, UNIVOCAL_QA_DIR, UNIVOCAL_QA_OUT and UNIVOCAL_QA_MOCKCTL")
        }
        let outURL = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        func console(_ line: String) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: ctl))
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try handle.close()
            note("mock> \(line)")
        }

        let relay = Relay()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(relay, name: ReadAloudBridge.messageHandlerName)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 300), configuration: config)
        webView.navigationDelegate = relay
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 760, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            config.userContentController.removeScriptMessageHandler(forName: ReadAloudBridge.messageHandlerName)
        }

        let backend = Backend(connectDir: URL(fileURLWithPath: dir), hotkeyTarget: true)
        let controller = ReadAloudController(backend: backend, openURL: { _ in })
        relay.controller = controller
        controller.documentTitle = { "hotkey.md" }
        controller.hotkeySource = { .preview }
        controller.startHotkeyIntegration()

        let html = try XCTUnwrap(MdReaderResources.previewHTMLURL)
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        try spin(until: "shell loaded", 30) { relay.loaded && controller.highlightMode != nil }
        let target = "The hotkey starts reading here."
        try evaluate(try XCTUnwrap(MarkdownRenderBridge.renderJS(for: """
            # Hotkey

            First paragraph that should be skipped.

            Second paragraph, also skipped.

            \(target) It keeps going after that.
            """)) + "; 0")

        // Connect as a hotkey target (the first time needs consent).
        let connected = Flag()
        let asked = Flag()
        let states = backend.connectionStates()
        let watcher = Task {
            for await state in states where state == .awaitingConsent { asked.value = true }
        }
        defer { watcher.cancel() }
        Task {
            _ = try? await backend.client.connect(launchIfNeeded: false)
            connected.value = true
        }
        try spin(until: "consent or connected", 30) { connected.value || asked.value }
        if !connected.value { try console("y") }
        try spin(until: "connected", 60) { connected.value }

        // Select the target sentence, then press the mock's hotkey with
        // this process frontmost.
        try evaluate("""
            (function () {
              var w = document.createTreeWalker(document.getElementById('previewmd-root'), NodeFilter.SHOW_TEXT);
              for (var n = w.nextNode(); n; n = w.nextNode()) {
                var i = n.data.indexOf('The hotkey');
                if (i >= 0) { window.getSelection().setBaseAndExtent(n, i, n, i + 10); return 0; }
              }
              return 1;
            })()
            """)
        try console("frontmost com.narnarlabs.previewmd \(getpid())")
        try console("hotkey")
        try spin(until: "routed and playing", 30) { controller.status == .playing }
        try spin(until: "first sentence", 10) { controller.currentSentence != nil }
        let sentence = try painted("univocal-sentence").joined()
        note("first sentence: \(sentence.debugDescription)")
        XCTAssertTrue(sentence.hasPrefix(target), "reading did not start at the selection: \(sentence)")
        try snapshot(outURL, "hotkey-routed")

        try console("hotkey")
        try spin(until: "toggled paused", 10) { controller.status == .paused }
        let frozen = try painted("univocal-word").joined()
        spinFor(1.0)
        XCTAssertEqual(try painted("univocal-word").joined(), frozen, "highlight moved while paused")
        try console("hotkey")
        try spin(until: "toggled playing", 10) { controller.status == .playing }
        controller.stop()
        try spin(until: "idle", 10) { controller.status == .idle }
        try log.joined(separator: "\n").write(to: outURL.appendingPathComponent("hotkey.log"),
                                              atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    @MainActor private final class Flag { var value = false }

    private func note(_ line: String) { log.append(line); print("[qa] " + line) }

    private func spinFor(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private struct Timeout: Error, CustomStringConvertible { let description: String }

    private func spin(until what: String, _ seconds: TimeInterval, _ done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { throw Timeout(description: "timed out waiting for \(what)") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    @discardableResult
    private func evaluate(_ js: String) throws -> Any? {
        var result: Result<Any?, Error>?
        webView.evaluateJavaScript(js) { value, error in
            result = error.map { .failure($0) } ?? .success(value)
        }
        try spin(until: "evaluate", 30) { result != nil }
        return try result!.get()
    }

    private func painted(_ name: String) throws -> [String] {
        let json = try evaluate("""
            JSON.stringify(PreviewMDReadAloud.highlightMode === 'mark'
              ? Array.from(document.querySelectorAll('mark.\(name)')).map(function (m) { return m.textContent; })
              : (CSS.highlights.get('\(name)') ? Array.from(CSS.highlights.get('\(name)')).map(function (r) { return r.toString(); }) : []))
            """) as? String ?? "[]"
        return (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String]) ?? []
    }

    private func snapshot(_ dir: URL, _ name: String) throws {
        var image: NSImage?
        webView.takeSnapshot(with: nil) { img, _ in image = img ?? NSImage() }
        try spin(until: "snapshot", 10) { image != nil }
        shot += 1
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: dir.appendingPathComponent(String(format: "%02d-%@.png", shot, name)))
    }
}
