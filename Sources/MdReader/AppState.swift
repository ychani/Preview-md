import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import WebKit

private let kBookmarkKey = "FolderSecurityBookmark"
private let kRecentsKey = "RecentFileURLs"
private let kMaxRecents = 10

private let kMarkdownExtensions: Set<String> = ["md", "markdown"]

@MainActor
final class AppState: ObservableObject {
    @Published var folderURL: URL?
    @Published var files: [MarkdownFile] = []
    @Published var selectedFile: MarkdownFile?
    @Published var viewMode: ViewMode = .preview

    // Editable text for the currently open file
    @Published var editingContent: String = ""

    // Snapshot of the last-saved (or just-loaded) content; isDirty derives from this
    @Published private var savedContent: String = ""

    /// True while a file is being read from disk or while the preview WebView is
    /// rendering it. The preview pane shows a spinner in its place.
    @Published var isLoading: Bool = false

    /// Up to `kMaxRecents` most-recently-opened files (or folders), newest first.
    @Published var recentURLs: [URL] = []

    // MARK: – Find state

    @Published var isFindBarVisible: Bool = false
    @Published var findQuery: String = ""
    @Published var findMatchCount: Int = 0
    @Published var findCurrentIndex: Int = 0

    /// Weak reference to the currently-mounted preview WebView so the find bar
    /// can drive its native find API. Registered by `MarkdownPreviewView`.
    weak var previewWebView: WKWebView?

    // MARK: – Table of Contents

    /// Headings extracted from the rendered preview. Populated by
    /// `MarkdownPreviewView` via a `tocUpdate` WKScriptMessageHandler.
    @Published var tocEntries: [TOCEntry] = []

    /// Whether the TOC side panel is visible.
    @Published var showTOC: Bool = false

    /// Latest request for the preview to scroll to a heading. The UUID ensures
    /// that two taps on the same entry each produce a distinct observable
    /// change so the preview coordinator can replay the scroll.
    @Published var scrollRequest: ScrollRequest?

    func scrollToHeading(_ headingID: String) {
        scrollRequest = ScrollRequest(id: UUID(), headingID: headingID)
    }

    var isDirty: Bool { editingContent != savedContent }

    init() {
        loadRecents()
        restoreBookmark()
    }

    // MARK: – Open (file or folder)

    /// Shows an NSOpenPanel that accepts either a `.md`/`.markdown` file or a folder.
    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Markdown file or a folder of Markdown files."
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.insert(md, at: 0) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    /// Routes an arbitrary URL (from the open panel, `onOpenURL`, Dock drop, or
    /// Finder double-click) to the right loader.
    func open(url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            // File/folder no longer exists — drop it from recents if present.
            removeRecent(url)
            return
        }
        if isDir.boolValue {
            saveBookmark(for: url)
            loadFolder(url)
        } else {
            openFile(at: url)
        }
        addRecent(url)
    }

    /// Opens a single Markdown file. Loads its containing folder into the sidebar
    /// so sibling files remain browsable, then selects the file.
    func openFile(at url: URL) {
        let folder = url.deletingLastPathComponent()
        saveBookmark(for: folder)
        loadFolder(folder, preferredSelection: url)
    }

    func loadFolder(_ url: URL, preferredSelection: URL? = nil) {
        folderURL = url
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)
            files = contents
                .filter { kMarkdownExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
                .map { fileURL in
                    let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                    return MarkdownFile(url: fileURL, content: text)
                }
        } catch {
            files = []
        }
        let target: MarkdownFile?
        if let preferred = preferredSelection,
           let match = files.first(where: { $0.url.standardizedFileURL == preferred.standardizedFileURL }) {
            target = match
        } else {
            target = files.first
        }
        if let first = target {
            selectFile(first)
        } else {
            selectedFile = nil
            editingContent = ""
            savedContent = ""
        }
    }

    /// Back-compat shim for existing call sites that used the folder-only entry point.
    func openFolderPanel() { openPanel() }

    // MARK: – File selection

    func selectFile(_ file: MarkdownFile) {
        isLoading = true
        let text = (try? String(contentsOf: file.url, encoding: .utf8)) ?? file.content
        if let idx = files.firstIndex(of: file) {
            files[idx].content = text
            selectedFile = files[idx]
        } else {
            var refreshed = file
            refreshed.content = text
            selectedFile = refreshed
        }
        editingContent = text
        savedContent = text
        // isLoading stays true until MarkdownPreviewView reports the render is
        // complete via `markPreviewRendered()`. For the Edit-only view mode there
        // is no preview — flip the flag on the next runloop tick so the spinner
        // doesn't get stuck if the user switched modes.
        if viewMode == .edit {
            DispatchQueue.main.async { [weak self] in
                self?.isLoading = false
            }
        }
    }

    /// Called by `MarkdownPreviewView` once the WebView has finished rendering
    /// the current markdown text. Clears the loading state.
    func markPreviewRendered() {
        if isLoading { isLoading = false }
    }

    // MARK: – Saving

    func saveCurrentFile() {
        guard let file = selectedFile else { return }
        do {
            try editingContent.write(to: file.url, atomically: true, encoding: .utf8)
            // Refresh the content in the files array
            if let idx = files.firstIndex(of: file) {
                files[idx].content = editingContent
            }
            savedContent = editingContent
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: – Bookmark persistence

    private func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            UserDefaults.standard.set(data, forKey: kBookmarkKey)
        } catch {
            // Bookmark creation can fail in sandboxed contexts; not fatal
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: kBookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else { return }
            if stale {
                saveBookmark(for: url)
            }
            loadFolder(url)
        } catch {
            UserDefaults.standard.removeObject(forKey: kBookmarkKey)
        }
    }

    // MARK: – Recent files

    private func loadRecents() {
        guard let strings = UserDefaults.standard.array(forKey: kRecentsKey) as? [String] else {
            return
        }
        recentURLs = strings.compactMap { URL(string: $0) }
    }

    private func persistRecents() {
        let strings = recentURLs.map { $0.absoluteString }
        UserDefaults.standard.set(strings, forKey: kRecentsKey)
    }

    private func addRecent(_ url: URL) {
        let standardized = url.standardizedFileURL
        recentURLs.removeAll { $0.standardizedFileURL == standardized }
        recentURLs.insert(standardized, at: 0)
        if recentURLs.count > kMaxRecents {
            recentURLs = Array(recentURLs.prefix(kMaxRecents))
        }
        persistRecents()
    }

    private func removeRecent(_ url: URL) {
        let standardized = url.standardizedFileURL
        let before = recentURLs.count
        recentURLs.removeAll { $0.standardizedFileURL == standardized }
        if recentURLs.count != before {
            persistRecents()
        }
    }

    func clearRecents() {
        recentURLs = []
        persistRecents()
    }

    // MARK: – Find

    func showFindBar() {
        isFindBarVisible = true
    }

    func hideFindBar() {
        isFindBarVisible = false
        findQuery = ""
        findMatchCount = 0
        findCurrentIndex = 0
        previewWebView?.evaluateJavaScript(
            "window.getSelection && window.getSelection().removeAllRanges();",
            completionHandler: nil)
    }

    func toggleFindBar() {
        if isFindBarVisible {
            hideFindBar()
        } else {
            showFindBar()
        }
    }

    func updateFindQuery(_ query: String) {
        findQuery = query
        guard !query.isEmpty else {
            findMatchCount = 0
            findCurrentIndex = 0
            return
        }
        recountMatches(for: query)
        performFind(query: query, backwards: false, wrap: true) { [weak self] found in
            guard let self else { return }
            self.findCurrentIndex = found && self.findMatchCount > 0 ? 1 : 0
        }
    }

    func findNext() {
        guard !findQuery.isEmpty else { return }
        performFind(query: findQuery, backwards: false, wrap: true) { [weak self] found in
            guard let self, found, self.findMatchCount > 0 else { return }
            self.findCurrentIndex = self.findCurrentIndex >= self.findMatchCount
                ? 1
                : self.findCurrentIndex + 1
        }
    }

    func findPrev() {
        guard !findQuery.isEmpty else { return }
        performFind(query: findQuery, backwards: true, wrap: true) { [weak self] found in
            guard let self, found, self.findMatchCount > 0 else { return }
            self.findCurrentIndex = self.findCurrentIndex <= 1
                ? self.findMatchCount
                : self.findCurrentIndex - 1
        }
    }

    private func performFind(
        query: String,
        backwards: Bool,
        wrap: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard let webView = previewWebView else {
            completion(false)
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = wrap
        config.caseSensitive = false
        webView.find(query, configuration: config) { result in
            completion(result.matchFound)
        }
    }

    private func recountMatches(for query: String) {
        guard let webView = previewWebView,
              let encoded = try? JSONSerialization.data(withJSONObject: [query]),
              let jsonArray = String(data: encoded, encoding: .utf8)
        else {
            findMatchCount = 0
            return
        }
        let js = """
        (function(q){
          if (!q) return 0;
          var text = (document.body && document.body.innerText) || '';
          var escaped = q.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
          var re = new RegExp(escaped, 'gi');
          var m = text.match(re);
          return m ? m.length : 0;
        })((\(jsonArray))[0])
        """
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            guard let self else { return }
            if let n = value as? Int {
                self.findMatchCount = n
            } else if let n = value as? NSNumber {
                self.findMatchCount = n.intValue
            } else {
                self.findMatchCount = 0
            }
            if self.findMatchCount == 0 {
                self.findCurrentIndex = 0
            } else if self.findCurrentIndex == 0 {
                self.findCurrentIndex = 1
            } else if self.findCurrentIndex > self.findMatchCount {
                self.findCurrentIndex = self.findMatchCount
            }
        }
    }
}
