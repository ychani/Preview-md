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
    /// The file being previewed. Scopes the remote-images opt-in (which
    /// resets when this changes).
    var documentURL: URL?

    init(
        markdownText: String,
        onRenderComplete: (() -> Void)? = nil,
        onTOCUpdate: (([TOCEntry]) -> Void)? = nil,
        scrollRequest: ScrollRequest? = nil,
        onWebViewReady: ((WKWebView?) -> Void)? = nil,
        documentURL: URL? = nil
    ) {
        self.markdownText = markdownText
        self.onRenderComplete = onRenderComplete
        self.onTOCUpdate = onTOCUpdate
        self.scrollRequest = scrollRequest
        self.onWebViewReady = onWebViewReady
        self.documentURL = documentURL
    }

    private static let messageNames = ["tocUpdate", "loadRemoteImages"]

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // No cookies, cache or storage written to disk, and nothing shared
        // with other web views.
        config.websiteDataStore = .nonPersistent()
        // Relative images next to the document; must be registered before
        // the web view is created.
        config.setURLSchemeHandler(
            coordinator.imageHandler, forURLScheme: LocalImageSchemeHandler.scheme)
        for name in Self.messageNames {
            config.userContentController.add(coordinator, name: name)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.setValue(false, forKey: "drawsBackground")
        // Let SwiftUI's parent `.onDrop` handle file drops instead of the
        // webview trying to navigate to the dropped file.
        webView.unregisterDraggedTypes()

        coordinator.webView = webView
        coordinator.pendingMarkdown = markdownText
        coordinator.onRenderComplete = onRenderComplete
        coordinator.onTOCUpdate = onTOCUpdate
        coordinator.onWebViewReady = onWebViewReady
        coordinator.setDocument(documentURL)
        coordinator.loadShell()
        onWebViewReady?(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onRenderComplete = onRenderComplete
        coordinator.onTOCUpdate = onTOCUpdate
        coordinator.onWebViewReady = onWebViewReady
        coordinator.setDocument(documentURL)
        coordinator.revalidateRemoteOptIn(markdown: markdownText)
        coordinator.scheduleRender(markdownText)
        coordinator.handleScrollRequest(scrollRequest)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        for name in messageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        coordinator.onWebViewReady?(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var pendingMarkdown: String = ""
        var onRenderComplete: (() -> Void)?
        var onTOCUpdate: (([TOCEntry]) -> Void)?
        var onWebViewReady: ((WKWebView?) -> Void)?
        let imageHandler = LocalImageSchemeHandler()
        /// What was last sent to `render()`: the text and the image base it
        /// was rendered with (a different folder must re-render).
        private struct RenderKey: Equatable {
            let markdown: String
            let imageBase: String?
        }
        private var lastRendered: RenderKey?
        private var isLoaded = false
        private var debounceItem: DispatchWorkItem?
        private var lastScrollRequestID: UUID?

        private var documentURL: URL?
        /// `previewmd-local://<token>/` for the document's folder, or nil.
        private var imageBase: String?

        /// What a remote-images opt-in applies to: the document, or — when the
        /// host passes no `documentURL` — the exact text, so the opt-in can
        /// never leak to a different document.
        private enum OptInScope: Equatable {
            case document(URL)
            case text(Int)
        }
        /// Set when the user clicked "Load remote images". In-memory only:
        /// never persisted, and reset as soon as the scope changes.
        private var remoteOptIn: OptInScope?
        private var remoteImagesAllowed: Bool { remoteOptIn != nil }
        /// The CSP mode of the shell currently loaded in the web view.
        private var shellAllowsRemoteImages = false

        // MARK: Document / shell

        func setDocument(_ url: URL?) {
            let normalized = url?.standardizedFileURL
            guard normalized != documentURL else { return }
            documentURL = normalized
            imageBase = normalized.map {
                imageHandler.register(folder: $0.deletingLastPathComponent())
            }
        }

        private func currentScope(for markdown: String) -> OptInScope {
            if let documentURL { return .document(documentURL) }
            return .text(markdown.hashValue)
        }

        /// Drops the remote-images opt-in once the previewed document (or
        /// text, without a document URL) is no longer the one it was granted
        /// for, and reloads the strict shell.
        func revalidateRemoteOptIn(markdown: String) {
            guard let optIn = remoteOptIn, optIn != currentScope(for: markdown) else { return }
            remoteOptIn = nil
            loadShell()
        }

        /// Loads preview.html. A meta-tag CSP cannot be relaxed in place, so
        /// switching remote images on or off means loading a fresh shell; the
        /// pending markdown is re-rendered once it finishes loading.
        func loadShell() {
            guard let webView, let htmlURL = MdReaderResources.previewHTMLURL else { return }
            isLoaded = false
            lastRendered = nil
            let readRoot = htmlURL.deletingLastPathComponent()
            if remoteImagesAllowed,
               let template = try? String(contentsOf: htmlURL, encoding: .utf8),
               let html = MarkdownRenderBridge.previewShellHTML(
                    template: template, allowRemoteImages: true) {
                shellAllowsRemoteImages = true
                webView.loadHTMLString(html, baseURL: htmlURL)
            } else {
                shellAllowsRemoteImages = false
                webView.loadFileURL(htmlURL, allowingReadAccessTo: readRoot)
            }
        }

        // MARK: Rendering

        func scheduleRender(_ markdown: String) {
            if RenderKey(markdown: markdown, imageBase: imageBase) == lastRendered { return }
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
            let key = RenderKey(markdown: pendingMarkdown, imageBase: imageBase)
            guard let js = MarkdownRenderBridge.renderJS(
                    for: key.markdown, imageBase: key.imageBase) else { return }
            webView.evaluateJavaScript(js) { [weak self] _, _ in
                self?.onRenderComplete?()
            }
            lastRendered = key
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

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            flushRender()
            // Safety net: clear the loading state as soon as the shell has
            // loaded, so the spinner disappears even if `render()` somehow
            // fails to call back (missing resources, JS error, etc.).
            onRenderComplete?()
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
            switch message.name {
            case "tocUpdate":
                onTOCUpdate?(Self.parseTOC(message.body))
            case "loadRemoteImages":
                guard !remoteImagesAllowed else { return }
                remoteOptIn = currentScope(for: pendingMarkdown)
                if !shellAllowsRemoteImages { loadShell() }
            default:
                break
            }
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
