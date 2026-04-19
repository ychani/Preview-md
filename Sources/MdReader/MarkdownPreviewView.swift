import AppKit
import SwiftUI
import WebKit

struct MarkdownPreviewView: NSViewRepresentable {
    let markdownText: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        if let htmlURL = Bundle.module.url(forResource: "preview", withExtension: "html") {
            let readRoot = htmlURL.deletingLastPathComponent()
            webView.loadFileURL(htmlURL, allowingReadAccessTo: readRoot)
        }

        context.coordinator.webView = webView
        context.coordinator.pendingMarkdown = markdownText
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.scheduleRender(markdownText)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var pendingMarkdown: String = ""
        private var lastRendered: String?
        private var isLoaded = false
        private var debounceItem: DispatchWorkItem?

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
            guard let data = try? JSONSerialization.data(
                    withJSONObject: [markdown], options: []),
                  let jsonArray = String(data: data, encoding: .utf8) else { return }
            // jsonArray looks like: ["..."], so take the first element safely in JS.
            let js = "render((\(jsonArray))[0])"
            webView.evaluateJavaScript(js, completionHandler: nil)
            lastRendered = markdown
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
    }
}
