import AppKit
import MdReaderCore
import SwiftUI
import WebKit

struct MarkdownPreviewView: NSViewRepresentable {
    let markdownText: String
    var onRenderComplete: (() -> Void)?
    var onTOCUpdate: (([TOCEntry]) -> Void)?
    var scrollRequest: ScrollRequest?
    var onWebViewReady: ((WKWebView?) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: "tocUpdate")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        if let htmlURL = MdReaderResources.previewHTMLURL {
            let readRoot = htmlURL.deletingLastPathComponent()
            webView.loadFileURL(htmlURL, allowingReadAccessTo: readRoot)
        }

        context.coordinator.webView = webView
        context.coordinator.pendingMarkdown = markdownText
        context.coordinator.onRenderComplete = onRenderComplete
        context.coordinator.onTOCUpdate = onTOCUpdate
        context.coordinator.onWebViewReady = onWebViewReady
        onWebViewReady?(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onRenderComplete = onRenderComplete
        context.coordinator.onTOCUpdate = onTOCUpdate
        context.coordinator.onWebViewReady = onWebViewReady
        context.coordinator.scheduleRender(markdownText)
        context.coordinator.handleScrollRequest(scrollRequest)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tocUpdate")
        coordinator.onWebViewReady?(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var pendingMarkdown: String = ""
        var onRenderComplete: (() -> Void)?
        var onTOCUpdate: (([TOCEntry]) -> Void)?
        var onWebViewReady: ((WKWebView?) -> Void)?
        private var lastRendered: String?
        private var isLoaded = false
        private var debounceItem: DispatchWorkItem?
        private var lastScrollRequestID: UUID?

        func scheduleRender(_ markdown: String) {
            if markdown == lastRendered { return }
            pendingMarkdown = markdown
            debounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.flushRender()
            }
            debounceItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
        }

        private func flushRender() {
            guard isLoaded, let webView else { return }
            let markdown = pendingMarkdown
            guard let js = MarkdownRenderBridge.renderJS(for: markdown) else { return }
            webView.evaluateJavaScript(js) { [weak self] _, _ in
                self?.onRenderComplete?()
            }
            lastRendered = markdown
        }

        func handleScrollRequest(_ request: ScrollRequest?) {
            guard let request, request.id != lastScrollRequestID else { return }
            lastScrollRequestID = request.id
            guard isLoaded, let webView else { return }
            guard let data = try? JSONSerialization.data(
                    withJSONObject: [request.headingID], options: []),
                  let arr = String(data: data, encoding: .utf8) else { return }
            let js = """
            (function(){var _id=(\(arr))[0];var _t=document.getElementById(_id);\
            if(_t){_t.scrollIntoView({behavior:'smooth',block:'start'});}})();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            flushRender()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            if navigationAction.navigationType == .linkActivated, let url {
                if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            if let scheme = url?.scheme, scheme != "file" && scheme != "about" {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "tocUpdate" else { return }
            let entries = Self.parseTOC(message.body)
            onTOCUpdate?(entries)
        }

        private static func parseTOC(_ body: Any) -> [TOCEntry] {
            guard let raw = body as? [[String: Any]] else { return [] }
            return raw.compactMap { dict in
                guard let level = dict["level"] as? Int,
                      let text = dict["text"] as? String,
                      let id = dict["id"] as? String,
                      !id.isEmpty else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return TOCEntry(level: level, text: trimmed, id: id)
            }
        }
    }
}
