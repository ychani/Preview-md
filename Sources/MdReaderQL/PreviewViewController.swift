import AppKit
import Cocoa
import MdReaderCore
import os.log
import Quartz
import WebKit

private let qlLog = Logger(subsystem: "com.preview-md.app.quicklook", category: "preview")

@objc(PreviewViewController)
public final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {

    private var webView: WKWebView!
    private var pendingMarkdown: String?
    private var pendingCompletion: ((Error?) -> Void)?
    private var didLoadShell = false

    public override func loadView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 800),
                                configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        self.webView = webView

        let container = NSView(frame: webView.frame)
        container.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        self.view = container

        if let htmlURL = MdReaderResources.previewHTMLURL {
            let readRoot = htmlURL.deletingLastPathComponent()
            webView.loadFileURL(htmlURL, allowingReadAccessTo: readRoot)
        }
    }

    // MARK: - QLPreviewingController

    /// Modern data-based preview (macOS 12+). With QLIsDataBasedPreview set in
    /// the Info.plist this is the entry point Quick Look actually uses; the
    /// HTML is rendered by Quick Look itself, with no WebView in this process.
    public func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        qlLog.info("providePreview: \(url.lastPathComponent, privacy: .public)")
        let markdown = try MarkdownDocumentIO.read(from: url).text
        let html = try MarkdownHTMLRenderer.renderDocument(
            markdown: markdown, title: url.lastPathComponent)
        qlLog.info("providePreview: rendered \(html.count) bytes of HTML")
        return QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 800, height: 900)
        ) { reply in
            reply.title = url.lastPathComponent
            reply.stringEncoding = .utf8
            return Data(html.utf8)
        }
    }

    /// Legacy view-based preview — kept as a fallback for contexts that do not
    /// use the data-based path.
    public func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        qlLog.info("preparePreviewOfFile: \(url.lastPathComponent, privacy: .public)")
        // Without the resource bundle the shell can never load and `didFinish`
        // never fires — fail fast so Quick Look falls back instead of hanging.
        guard MdReaderResources.previewHTMLURL != nil else {
            qlLog.error("resource bundle missing — failing preview")
            handler(NSError(
                domain: "com.preview-md.app.quicklook", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Preview resources missing from the extension bundle"]))
            return
        }
        let markdown: String
        do {
            markdown = try MarkdownDocumentIO.read(from: url).text
        } catch {
            qlLog.error("read failed: \(error.localizedDescription, privacy: .public)")
            handler(error)
            return
        }
        pendingMarkdown = markdown
        pendingCompletion = handler
        if didLoadShell {
            flush()
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        qlLog.info("shell loaded")
        didLoadShell = true
        flush()
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Block any navigation away from the preview shell.
        if let scheme = navigationAction.request.url?.scheme,
           scheme != "file" && scheme != "about" {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - Private

    private func flush() {
        guard let markdown = pendingMarkdown else { return }
        guard let js = MarkdownRenderBridge.renderJS(for: markdown) else {
            pendingCompletion?(nil)
            pendingCompletion = nil
            pendingMarkdown = nil
            return
        }
        webView.evaluateJavaScript(js) { [weak self] _, error in
            if let error {
                qlLog.error("render JS failed: \(error.localizedDescription, privacy: .public)")
            } else {
                qlLog.info("render complete")
            }
            self?.pendingCompletion?(error)
            self?.pendingCompletion = nil
            self?.pendingMarkdown = nil
        }
    }
}
