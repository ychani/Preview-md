import AppKit
import Cocoa
import MdReaderCore
import Quartz
import WebKit

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

    public func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let markdown: String
        do {
            markdown = try String(contentsOf: url, encoding: .utf8)
        } catch {
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
            self?.pendingCompletion?(error)
            self?.pendingCompletion = nil
            self?.pendingMarkdown = nil
        }
    }
}
