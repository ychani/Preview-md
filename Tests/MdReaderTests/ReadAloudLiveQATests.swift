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
@MainActor
final class ReadAloudLiveQATests: XCTestCase {
    private final class Backend: ReadAloudBackend, @unchecked Sendable {
        let client: UnivocalClient
        init(connectDir: URL) {
            var config = UnivocalConfiguration(client: UnivocalClientIdentity(
                id: "com.narnarlabs.previewmd", name: "PreviewMD (QA)", version: "qa"))
            config.connectDirectory = connectDir
            config.tokenStore = InMemoryTokenStore()
            client = UnivocalClient(configuration: config)
        }
        func availability() -> UnivocalAvailability {
            .installed(appURL: URL(fileURLWithPath: "/Applications"), running: true)
        }
        func connectionStates() -> AsyncStream<UnivocalConnectionState> { client.stateUpdates() }
        func startReading(_ request: ReadRequest) async throws -> any ReadAloudSession {
            try await client.read(request)
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

        controller.toggle()
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
            if i == 3 {
                controller.toggle()  // pause
                try spin(until: "paused", 10) { controller.status == .paused }
                let frozen = try painted("univocal-word").joined()
                spinFor(1.0)
                XCTAssertEqual(try painted("univocal-word").joined(), frozen, "highlight moved while paused")
                note("paused on \(frozen.debugDescription); resuming")
                controller.toggle()
                try spin(until: "resumed", 10) { controller.status == .playing }
            }
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

    // MARK: - Helpers

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
