import AppKit
import Combine
import Foundation
import MdReaderCore
import UniformTypeIdentifiers
import WebKit

private let kBookmarkKey = "FolderSecurityBookmark"
private let kRecentsKey = "RecentFileURLs"
private let kMaxRecents = 10

private let kMarkdownExtensions: Set<String> = ["md", "markdown"]

/// The sidebar can display one of two populations: the contents of a folder the
/// user opened, or an ad-hoc list of explicitly-opened files (picker, drag,
/// Finder double-click).
enum SidebarMode {
    case openedFiles
    case folder
}

@MainActor
final class AppState: ObservableObject {
    @Published var folderURL: URL?
    @Published var files: [MarkdownFile] = []
    @Published var selectedFile: MarkdownFile?
    @Published var viewMode: ViewMode = .preview

    /// Which population `files` represents. Drives sidebar header + context menu.
    @Published var sidebarMode: SidebarMode = .openedFiles

    /// Whether the file sidebar is visible. Defaults to hidden for single-file
    /// opens; shown for folder opens and drag-to-open.
    @Published var showSidebar: Bool = false

    // Editable text for the currently open file
    @Published var editingContent: String = ""

    // Snapshot of the last-saved (or just-loaded) content; isDirty derives from this
    @Published private var savedContent: String = ""

    /// True while a file is being read from disk or while the preview WebView is
    /// rendering it. The preview pane shows a spinner in its place.
    @Published var isLoading: Bool = false

    /// Non-nil when the selected file could not be read or decoded. While set,
    /// the detail pane shows the error instead of the preview and saving is
    /// disabled so a failed read can never overwrite the file on disk.
    @Published var loadErrorMessage: String?

    /// Encoding the current file was decoded with; saves write back in the
    /// same encoding so opening a Latin-1 file doesn't silently convert it.
    private var currentEncoding: String.Encoding = .utf8

    /// Modification date of the file as of the last load/save. Used to detect
    /// external changes before overwriting on ⌘S.
    private var loadedModificationDate: Date?

    /// Watches the selected file for external writes/renames and reloads the
    /// content when the in-app copy has no unsaved edits.
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileWatcherReloadWork: DispatchWorkItem?

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

    /// Routes an arbitrary URL (from the open panel, `onOpenURL`, or Finder
    /// double-click of a single file) to the right loader. A single-file open
    /// hides the sidebar; a folder open shows it.
    func open(url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
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

    /// Opens a single Markdown file as the sole entry in the sidebar. Hides the
    /// sidebar by default — user can reveal it with ⌘⇧L.
    func openFile(at url: URL) {
        sidebarMode = .openedFiles
        folderURL = nil
        showSidebar = false
        let file = MarkdownFile(url: url)
        files = [file]
        selectFile(file)
    }

    /// Adds one or more files to the opened-files list. Used for drag-and-drop
    /// onto the window or Dock icon. Preserves existing entries, dedupes by
    /// standardized URL, and reveals the sidebar.
    func openDroppedFiles(_ urls: [URL]) {
        let markdownURLs = urls.filter {
            kMarkdownExtensions.contains($0.pathExtension.lowercased())
        }
        guard !markdownURLs.isEmpty else { return }

        // Drops discard any previously-loaded folder context.
        if sidebarMode == .folder {
            files = []
            folderURL = nil
            sidebarMode = .openedFiles
        }

        let existing = Set(files.map { $0.url.standardizedFileURL })
        var firstNew: MarkdownFile?
        for url in markdownURLs {
            let std = url.standardizedFileURL
            if existing.contains(std) { continue }
            let file = MarkdownFile(url: std)
            files.append(file)
            if firstNew == nil { firstNew = file }
        }

        showSidebar = true

        if selectedFile == nil, let target = firstNew ?? files.first {
            selectFile(target)
        }

        for url in markdownURLs { addRecent(url) }
    }

    /// Removes a file from the session list. Session-only — files are not
    /// deleted on disk. Valid only in `.openedFiles` mode; the folder view has
    /// no "remove" concept.
    func removeFromList(_ file: MarkdownFile) {
        guard sidebarMode == .openedFiles else { return }
        guard let idx = files.firstIndex(of: file) else { return }
        let wasSelected = selectedFile == file
        files.remove(at: idx)
        if wasSelected {
            if let next = files.first {
                selectFile(next)
            } else {
                clearSelection()
            }
        }
    }

    private func clearSelection() {
        selectedFile = nil
        editingContent = ""
        savedContent = ""
        loadErrorMessage = nil
        loadedModificationDate = nil
        currentEncoding = .utf8
        stopWatchingFile()
    }

    func toggleSidebar() {
        showSidebar.toggle()
    }

    func loadFolder(_ url: URL, preferredSelection: URL? = nil) {
        folderURL = url
        sidebarMode = .folder
        showSidebar = true
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)
            // Contents are loaded lazily in selectFile — listing a large folder
            // must not read every file up front.
            files = contents
                .filter { kMarkdownExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
                .map { MarkdownFile(url: $0) }
        } catch {
            files = []
            presentError(
                title: "Could not open folder",
                message: "“\(url.lastPathComponent)” could not be read: \(error.localizedDescription)")
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
            clearSelection()
        }
    }

    /// Back-compat shim for existing call sites that used the folder-only entry point.
    func openFolderPanel() { openPanel() }

    // MARK: – File selection

    func selectFile(_ file: MarkdownFile) {
        isLoading = true
        loadErrorMessage = nil

        let text: String
        do {
            let document = try MarkdownDocumentIO.read(from: file.url)
            text = document.text
            currentEncoding = document.encoding
            loadedModificationDate = modificationDate(of: file.url)
        } catch {
            text = ""
            currentEncoding = .utf8
            loadedModificationDate = nil
            loadErrorMessage = error.localizedDescription
        }

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
        if loadErrorMessage == nil {
            watchFile(at: file.url)
        } else {
            stopWatchingFile()
            isLoading = false
            return
        }
        // isLoading stays true until MarkdownPreviewView reports the render is
        // complete via `markPreviewRendered()`. For the Edit-only view mode there
        // is no preview — flip the flag on the next runloop tick so the spinner
        // doesn't get stuck if the user switched modes.
        if viewMode == .edit {
            DispatchQueue.main.async { [weak self] in
                self?.isLoading = false
            }
        } else {
            // Safety timeout: if the preview pipeline never calls back (view
            // not mounted yet, navigation stalls, etc.), force-clear so the
            // spinner doesn't strand the UI.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
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

    /// Saves the current file. Returns true when the file was written (used by
    /// the quit guard to decide whether termination may proceed).
    @discardableResult
    func saveCurrentFile() -> Bool {
        guard let file = selectedFile else { return false }
        guard loadErrorMessage == nil else { return false }

        // The file changed on disk since we loaded it — don't clobber the
        // other writer silently.
        if let loaded = loadedModificationDate,
           let onDisk = modificationDate(of: file.url),
           onDisk > loaded {
            let alert = NSAlert()
            alert.messageText = "“\(file.name)” has changed on disk"
            alert.informativeText = "Another application modified this file since you opened it. "
                + "Overwriting will discard those external changes."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Reload From Disk")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                break // fall through to the write
            case .alertSecondButtonReturn:
                selectFile(file)
                return false
            default:
                return false
            }
        }

        do {
            try write(editingContent, to: file.url)
        } catch {
            // Most likely cause: content no longer representable in the file's
            // original encoding (e.g. emoji added to a Latin-1 file).
            if currentEncoding != .utf8 {
                let alert = NSAlert()
                alert.messageText = "Could not save in the file's original encoding"
                alert.informativeText = "\(error.localizedDescription)\n\nSave as UTF-8 instead?"
                alert.addButton(withTitle: "Save as UTF-8")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
                currentEncoding = .utf8
                do {
                    try write(editingContent, to: file.url)
                } catch {
                    presentError(title: "Could not save file", message: error.localizedDescription)
                    return false
                }
            } else {
                presentError(title: "Could not save file", message: error.localizedDescription)
                return false
            }
        }

        if let idx = files.firstIndex(of: file) {
            files[idx].content = editingContent
        }
        savedContent = editingContent
        loadedModificationDate = modificationDate(of: file.url)
        return true
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: currentEncoding)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: – External change watching

    /// Watches the selected file and reloads it when another process writes to
    /// it, as long as there are no unsaved in-app edits. Editors that save via
    /// atomic rename emit `.rename`, so the watch is re-established on the
    /// path after every event.
    private func watchFile(at url: URL) {
        stopWatchingFile()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            self?.scheduleExternalReload(for: url)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    private func stopWatchingFile() {
        fileWatcherReloadWork?.cancel()
        fileWatcherReloadWork = nil
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    /// Debounced: editors commonly emit several events per save.
    private func scheduleExternalReload(for url: URL) {
        fileWatcherReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleExternalChange(at: url)
        }
        fileWatcherReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func handleExternalChange(at url: URL) {
        guard selectedFile?.url.standardizedFileURL == url.standardizedFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Deleted (or mid-rename). Keep the buffer so the user can re-save;
            // the save path will simply recreate the file.
            stopWatchingFile()
            return
        }
        // With unsaved edits, don't clobber the buffer — the save-time
        // conflict check handles the collision instead.
        guard !isDirty else {
            watchFile(at: url) // re-arm across atomic renames
            return
        }
        guard let document = try? MarkdownDocumentIO.read(from: url) else { return }
        currentEncoding = document.encoding
        loadedModificationDate = modificationDate(of: url)
        if document.text != savedContent {
            if let idx = files.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                files[idx].content = document.text
                selectedFile = files[idx]
            }
            editingContent = document.text
            savedContent = document.text
        }
        watchFile(at: url)
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
