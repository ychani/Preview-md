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
    /// Opens another local Markdown file the document links to (relative
    /// `[x](other.md)`). Nil falls back to asking Launch Services to open the
    /// file with this app.
    var onOpenLocalFile: ((URL) -> Void)?
    /// The workspace root containing `documentURL`, if any: images (relative
    /// ones and wikilink embeds) may come from anywhere inside it. Nil serves
    /// the document's own folder only.
    var workspaceRoot: URL?
    /// Resolves `[[wikilinks]]`; nil when there is no workspace (links then
    /// render as plain links). `wikiLinkIndexVersion` changes whenever the
    /// index is replaced, so the preview knows to re-resolve.
    var wikiLinkIndex: WikiLinkIndex?
    var wikiLinkIndexVersion: Int = 0
    /// Opens the note a wikilink resolved to. Returns false if nothing was
    /// opened (e.g. the user cancelled the unsaved-changes prompt). Nil falls
    /// back to `onOpenLocalFile`.
    var onOpenWikiLink: ((URL) -> Bool)?
    /// False while the document's text is still being read (the preview is
    /// showing a placeholder): a pending wikilink `#heading` scroll waits for
    /// the real content.
    var isContentReady: Bool = true
    /// Messages from read-aloud.js (`ReadAloudBridge`), with the web view
    /// that posted them.
    var onReadAloudMessage: ((ReadAloudBridge.Message, WKWebView?) -> Void)?
    @AppStorage(PreviewSettings.zoomKey) private var zoom: Double = PreviewSettings.defaultZoom

    init(
        markdownText: String,
        onRenderComplete: (() -> Void)? = nil,
        onTOCUpdate: (([TOCEntry]) -> Void)? = nil,
        scrollRequest: ScrollRequest? = nil,
        onWebViewReady: ((WKWebView?) -> Void)? = nil,
        documentURL: URL? = nil,
        onOpenLocalFile: ((URL) -> Void)? = nil,
        workspaceRoot: URL? = nil,
        wikiLinkIndex: WikiLinkIndex? = nil,
        wikiLinkIndexVersion: Int = 0,
        onOpenWikiLink: ((URL) -> Bool)? = nil,
        isContentReady: Bool = true,
        onReadAloudMessage: ((ReadAloudBridge.Message, WKWebView?) -> Void)? = nil
    ) {
        self.markdownText = markdownText
        self.onRenderComplete = onRenderComplete
        self.onTOCUpdate = onTOCUpdate
        self.scrollRequest = scrollRequest
        self.onWebViewReady = onWebViewReady
        self.documentURL = documentURL
        self.onOpenLocalFile = onOpenLocalFile
        self.workspaceRoot = workspaceRoot
        self.wikiLinkIndex = wikiLinkIndex
        self.wikiLinkIndexVersion = wikiLinkIndexVersion
        self.onOpenWikiLink = onOpenWikiLink
        self.isContentReady = isContentReady
        self.onReadAloudMessage = onReadAloudMessage
    }

    private static let messageNames = [
        "tocUpdate", "loadRemoteImages", "openLocalFile", "openWikiLink",
        ReadAloudBridge.messageHandlerName,
    ]

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
        webView.pageZoom = CGFloat(PreviewSettings.clamp(zoom))

        coordinator.webView = webView
        coordinator.pendingMarkdown = markdownText
        coordinator.onRenderComplete = onRenderComplete
        coordinator.onTOCUpdate = onTOCUpdate
        coordinator.onWebViewReady = onWebViewReady
        coordinator.onOpenLocalFile = onOpenLocalFile
        coordinator.onOpenWikiLink = onOpenWikiLink
        coordinator.onReadAloudMessage = onReadAloudMessage
        coordinator.setDocument(documentURL, workspaceRoot: workspaceRoot)
        coordinator.setWikiLinkIndex(wikiLinkIndex, version: wikiLinkIndexVersion)
        coordinator.isContentReady = isContentReady
        coordinator.loadShell()
        onWebViewReady?(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let pageZoom = CGFloat(PreviewSettings.clamp(zoom))
        if webView.pageZoom != pageZoom {
            webView.pageZoom = pageZoom
        }
        let coordinator = context.coordinator
        coordinator.onRenderComplete = onRenderComplete
        coordinator.onTOCUpdate = onTOCUpdate
        coordinator.onWebViewReady = onWebViewReady
        coordinator.onOpenLocalFile = onOpenLocalFile
        coordinator.onOpenWikiLink = onOpenWikiLink
        coordinator.onReadAloudMessage = onReadAloudMessage
        coordinator.setDocument(documentURL, workspaceRoot: workspaceRoot)
        coordinator.setWikiLinkIndex(wikiLinkIndex, version: wikiLinkIndexVersion)
        coordinator.isContentReady = isContentReady
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
        var onOpenLocalFile: ((URL) -> Void)?
        var onOpenWikiLink: ((URL) -> Bool)?
        var onReadAloudMessage: ((ReadAloudBridge.Message, WKWebView?) -> Void)?
        var isContentReady = true
        let imageHandler = LocalImageSchemeHandler()
        /// The inputs of a render, compared cheaply to skip redundant ones
        /// (the wikilink map is derived from them in `flushRender`).
        private struct RenderInput: Equatable {
            let markdown: String
            let documentURL: URL?
            let bases: LocalImageSchemeHandler.Bases?
            let wikiLinkIndexVersion: Int?
        }
        /// What was last sent to `render()`: the text, the image bases and
        /// the wikilink map it was rendered with.
        private struct RenderKey: Equatable {
            let markdown: String
            let bases: LocalImageSchemeHandler.Bases?
            let wikiLinks: [String: WikiLinkResolution]?
        }
        private var lastInput: RenderInput?
        private var lastRendered: RenderKey?
        /// Top of the page for a newly opened document; same place while the
        /// same one re-renders (including across an opt-in shell reload).
        private var scrollTracker = PreviewScrollTracker()
        /// Bumped per flush; a map computed off the main thread for an older
        /// flush is dropped.
        private var renderSequence = 0
        private var isLoaded = false
        private var debounceItem: DispatchWorkItem?
        private var lastScrollRequestID: UUID?

        private var documentURL: URL?
        private var workspaceRoot: URL?
        /// Image bases for the document (its root and folder), or nil.
        private var bases: LocalImageSchemeHandler.Bases?
        private var wikiLinkIndex: WikiLinkIndex?
        private var wikiLinkIndexVersion = 0

        /// A `#heading` from a clicked `[[note#heading]]`, scrolled to once
        /// `url`'s real content has rendered.
        private var pendingHeading: (url: URL, heading: String)?

        /// Documents at least this large (UTF-8 bytes) have their wikilink
        /// map computed off the main thread (~20 ms per MB).
        private static let asyncWikiLinkThreshold = 128 * 1024

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

        func setDocument(_ url: URL?, workspaceRoot root: URL?) {
            let normalized = url?.standardizedFileURL
            guard normalized != documentURL || root != workspaceRoot else { return }
            documentURL = normalized
            workspaceRoot = root
            bases = normalized.map { imageHandler.register(documentURL: $0, root: root) }
            if let pending = pendingHeading,
               normalized.map(FileNode.canonicalURL) != pending.url {
                pendingHeading = nil
            }
        }

        func setWikiLinkIndex(_ index: WikiLinkIndex?, version: Int) {
            wikiLinkIndex = index
            wikiLinkIndexVersion = version
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
            lastInput = nil
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

        private func currentInput(_ markdown: String) -> RenderInput {
            RenderInput(markdown: markdown, documentURL: documentURL, bases: bases,
                        wikiLinkIndexVersion: wikiLinkIndex == nil ? nil : wikiLinkIndexVersion)
        }

        func scheduleRender(_ markdown: String) {
            let pendingScroll = pendingHeading != nil && isContentReady
            if currentInput(markdown) == lastInput, !pendingScroll { return }
            pendingMarkdown = markdown
            debounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.flushRender()
            }
            debounceItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
        }

        private func flushRender() {
            guard isLoaded, webView != nil else { return }
            let input = currentInput(pendingMarkdown)
            lastInput = input
            renderSequence &+= 1
            let sequence = renderSequence
            let ready = isContentReady
            guard let index = wikiLinkIndex, let documentURL else {
                evaluateRender(input, wikiLinks: nil, contentReady: ready, sequence: sequence)
                return
            }
            if input.markdown.utf8.count < Self.asyncWikiLinkThreshold {
                let map = index.resolutions(in: input.markdown, from: documentURL)
                evaluateRender(input, wikiLinks: map, contentReady: ready, sequence: sequence)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let map = index.resolutions(in: input.markdown, from: documentURL)
                DispatchQueue.main.async {
                    self?.evaluateRender(input, wikiLinks: map, contentReady: ready, sequence: sequence)
                }
            }
        }

        private func evaluateRender(
            _ input: RenderInput, wikiLinks: [String: WikiLinkResolution]?,
            contentReady: Bool, sequence: Int
        ) {
            guard sequence == renderSequence, isLoaded, let webView else { return }
            let key = RenderKey(markdown: input.markdown, bases: input.bases, wikiLinks: wikiLinks)
            var js = ""
            if key != lastRendered {
                let scroll = scrollTracker.scroll(forRenderOf: input.documentURL)
                guard let render = MarkdownRenderBridge.renderJS(
                        for: key.markdown, imageBase: key.bases?.imageBase,
                        imageRootBase: key.bases?.rootBase, wikiLinks: key.wikiLinks,
                        scroll: scroll) else { return }
                js = render
                lastRendered = key
            }
            // The heading of a just-followed `[[note#heading]]`, once that
            // note's real text is on the page.
            if contentReady, let pending = pendingHeading,
               input.documentURL.map(FileNode.canonicalURL) == pending.url,
               let scroll = Self.scrollToHeadingTextJS(pending.heading) {
                pendingHeading = nil
                js += js.isEmpty ? scroll : ";" + scroll
            }
            guard !js.isEmpty else {
                onRenderComplete?()
                return
            }
            webView.evaluateJavaScript(js) { [weak self] _, _ in
                self?.onRenderComplete?()
            }
        }

        /// JS that scrolls to the heading whose text is `heading`, using the
        /// page's own GitHub-style slugs (`slugify` / `scrollToFragment` in
        /// preview.js). For Obsidian's nested `A#B` form the last part wins.
        private static func scrollToHeadingTextJS(_ heading: String) -> String? {
            let last = heading.split(separator: "#").last.map(String.init) ?? heading
            let text = last.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
                  let arr = String(data: data, encoding: .utf8) else { return nil }
            return "(typeof scrollToFragment===\"function\"&&typeof slugify===\"function\""
                + "&&scrollToFragment(slugify((\(arr))[0])))"
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
                // preview.js handles #fragment and relative links itself; this
                // is the backstop. Same-document fragment jumps may proceed.
                if Self.isSameDocumentFragment(url, current: webView.url) {
                    decisionHandler(.allow)
                    return
                }
                if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                    NSWorkspace.shared.open(url)
                }
                // Everything else (file: links to non-Markdown files, other
                // schemes) is cancelled.
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
            case "openLocalFile":
                guard let href = message.body as? String,
                      let documentURL,
                      let target = MarkdownRenderBridge.resolveMarkdownLink(
                        href, documentURL: documentURL) else { return }
                openLocalFile(target)
            case "openWikiLink":
                guard let ref = message.body as? String else { return }
                openWikiLink(ref)
            case "loadRemoteImages":
                guard !remoteImagesAllowed else { return }
                remoteOptIn = currentScope(for: pendingMarkdown)
                if !shellAllowsRemoteImages {
                    let scrollY = ((message.body as? [String: Any])?["scrollY"] as? NSNumber)?.doubleValue
                    scrollTracker.shellWillReload(document: documentURL, scrollY: scrollY)
                    loadShell()
                }
            case ReadAloudBridge.messageHandlerName:
                guard let parsed = ReadAloudBridge.parseMessage(message.body) else { return }
                onReadAloudMessage?(parsed, message.webView)
            default:
                break
            }
        }

        /// Follows a clicked wikilink (`target` or `target#heading`, as
        /// preview.js posts it): re-resolves it from the current document,
        /// opens the note (or an image in its default app) and, for a
        /// heading, scrolls to it once the note has rendered. Unresolved
        /// links beep.
        private func openWikiLink(_ ref: String) {
            guard let documentURL, let link = WikiLink.parse(ref) else { return }
            guard !link.target.isEmpty else {
                // `[[#heading]]` — preview.js scrolls these itself.
                return
            }
            guard let resolution = wikiLinkIndex?.resolve(link, from: documentURL) else {
                NSSound.beep()
                return
            }
            switch resolution.kind {
            case .image:
                NSWorkspace.shared.open(resolution.url)
            case .note:
                let target = FileNode.canonicalURL(resolution.url)
                if target == FileNode.canonicalURL(documentURL) {
                    // A link to this very note: just scroll.
                    if let heading = link.heading, let js = Self.scrollToHeadingTextJS(heading) {
                        webView?.evaluateJavaScript(js, completionHandler: nil)
                    }
                    return
                }
                let opened: Bool
                if let onOpenWikiLink {
                    opened = onOpenWikiLink(resolution.url)
                } else {
                    openLocalFile(resolution.url)
                    opened = true
                }
                if opened, let heading = link.heading {
                    pendingHeading = (target, heading)
                }
            }
        }

        private func openLocalFile(_ url: URL) {
            if let onOpenLocalFile {
                onOpenLocalFile(url)
                return
            }
            // No host callback: hand the file to Launch Services, aimed at
            // this app when running as a bundle.
            let app = Bundle.main.bundleURL
            if app.pathExtension == "app" {
                NSWorkspace.shared.open(
                    [url], withApplicationAt: app,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil)
            }
        }

        private static func isSameDocumentFragment(_ url: URL, current: URL?) -> Bool {
            guard url.fragment != nil, let current,
                  var target = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  var here = URLComponents(url: current, resolvingAgainstBaseURL: true)
            else { return false }
            target.fragment = nil
            here.fragment = nil
            return target == here
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
