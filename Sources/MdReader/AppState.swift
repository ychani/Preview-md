import AppKit
import Combine
import Foundation
import MdReaderCore
import UniformTypeIdentifiers
import WebKit

/// Pre-workspace key: one bookmark for the last opened folder. Migrated to
/// `kWorkspaceBookmarksKey` on first launch.
private let kLegacyBookmarkKey = "FolderSecurityBookmark"
/// The workspace's root folders, as an array of bookmarks in root order.
private let kWorkspaceBookmarksKey = "WorkspaceRootBookmarks"
private let kRecentsKey = "RecentFileURLs"
private let kMaxRecents = 10

/// The sidebar can display one of two populations: the folders of the
/// workspace (one or more roots the user opened), or an ad-hoc list of
/// explicitly-opened files (picker, drag, Finder double-click).
enum SidebarMode {
    case openedFiles
    case folder
}

/// One root folder of the workspace, as the sidebar shows it.
struct RootState: Identifiable, Equatable {
    /// Canonical (`FileNode.canonicalURL`), equal to its tree's `rootURL`.
    let url: URL
    /// Nil until the first scan lands.
    var tree: FolderTree?
    /// True while the first scan runs.
    var isScanning = true
    /// True once the folder was deleted, renamed or moved away. Its last
    /// tree stays on screen; updates stop.
    var isMissing = false

    /// The tree hit the file cap.
    var isTruncated: Bool { tree?.isTruncated ?? false }
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor
final class AppState: ObservableObject {
    /// The app's one AppState (`MdReaderApp`'s `@StateObject`). The app
    /// delegate reaches it for Univocal wakes even when no window has
    /// appeared to hand it over.
    static let shared = AppState()

    @Published var files: [MarkdownFile] = []
    @Published var selectedFile: MarkdownFile? {
        didSet {
            if oldValue?.url != selectedFile?.url { readAloud.documentDidChange() }
        }
    }
    @Published var viewMode: ViewMode = .preview {
        didSet {
            // Edit view: no preview to highlight, so stop rather than read
            // on invisibly. An editor reading (Univocal's hotkey) stops on
            // any switch: its editor is replaced.
            if viewMode != oldValue { readAloud.viewModeDidChange(toEdit: viewMode == .edit) }
        }
    }

    /// Read Aloud via Univocal (toolbar, Edit ▸ Read Aloud).
    let readAloud = ReadAloudController()

    /// A document is on screen in Preview or Split view (Read Aloud reads
    /// the preview).
    var canReadAloud: Bool {
        selectedFile != nil && viewMode != .edit && loadErrorMessage == nil
    }

    /// What Univocal's read hotkey reads now: the preview, or the editor in
    /// Edit view (in Split view only while the editor has focus). All
    /// windows share this state, so the key window decides only whether
    /// there is one and which pane has focus.
    func readAloudHotkeySource() -> ReadAloudController.HotkeySource {
        guard selectedFile != nil, loadErrorMessage == nil else { return .noDocument }
        guard let window = Self.documentWindow() else { return .noWindow }
        if isReadingFile { return .loading }
        func editor(requireFocus: Bool) -> (any ReadAloudEditorSurface)? {
            EditorTextViewLocator.textView(in: window, showing: editingContent, requireFocus: requireFocus)
                .map { TextViewReadAloudSurface(textView: $0) }
        }
        switch viewMode {
        case .preview:
            return .preview
        case .edit:
            return .editor(editor(requireFocus: false))
        case .split:
            return editor(requireFocus: true).map { .editor($0) } ?? .preview
        }
    }

    /// The key (else main) window when it is a document window — not the
    /// About panel or an alert.
    static func documentWindow() -> NSWindow? {
        [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }.first { !($0 is NSPanel) && $0.isVisible }
    }

    /// Which population `files` represents. Drives sidebar header + context menu.
    @Published var sidebarMode: SidebarMode = .openedFiles

    /// Whether the file sidebar is visible. Defaults to hidden for single-file
    /// opens; shown for folder opens and drag-to-open.
    @Published var showSidebar: Bool = false

    // Editable text for the currently open file. Edits are refused while the
    // file is still being read (they would be overwritten by the read) and
    // for read-only (large) files.
    @Published var editingContent: String = "" {
        didSet {
            if isReadingFile || isReadOnly, editingContent != savedContent {
                editingContent = savedContent
            }
        }
    }

    // Snapshot of the last-saved (or just-loaded) content; isDirty derives from this
    @Published private var savedContent: String = ""

    /// True while a file is being read from disk or while the preview WebView is
    /// rendering it. The preview pane shows a spinner in its place.
    @Published var isLoading: Bool = false

    /// True while the selected file's bytes are being read off the main thread.
    @Published private(set) var isReadingFile: Bool = false

    /// True when the selected file is larger than
    /// `MarkdownDocumentIO.largeFileThreshold`: it is shown, but editing and
    /// saving are disabled to keep the app responsive.
    @Published private(set) var isReadOnly: Bool = false

    /// Bumped on every selection; reads that complete for an older
    /// generation are dropped so a slow read can't replace a newer selection.
    private var loadGeneration = 0

    /// Non-nil when the selected file could not be read or decoded. While set,
    /// the detail pane shows the error instead of the preview and saving is
    /// disabled so a failed read can never overwrite the file on disk.
    @Published var loadErrorMessage: String?

    /// On-disk format (encoding, BOM, line endings) the current file was read
    /// with; saves write back in the same format so opening a Latin-1 or CRLF
    /// file doesn't silently convert it.
    private var currentFormat: MarkdownDocumentIO.Format = .utf8

    /// Modification date of the file as of the last load/save. Used to detect
    /// external changes before overwriting on ⌘S.
    private var loadedModificationDate: Date?

    /// Watches the selected file for external writes/renames. Reloads when the
    /// in-app copy has no unsaved edits; otherwise asks the user.
    private var fileWatcher: FileWatcher?
    private var isShowingChangedOnDiskAlert = false

    /// Up to `kMaxRecents` most-recently-opened files (or folders), newest first.
    @Published var recentURLs: [URL] = []

    // MARK: – Workspace (folder explorer)

    /// The workspace's root folders, in order (folder mode only). `files` is
    /// their trees' `flatFiles`, concatenated in root order.
    @Published private(set) var roots: [RootState] = []

    /// Folders shown expanded in the sidebar tree, by tree URL (a root's own
    /// URL for its top-level row). Survives live updates (a folder that
    /// disappears and comes back stays expanded).
    @Published var expandedFolders: Set<URL> = []

    /// Asks the sidebar to scroll a row into view (after auto-reveal).
    @Published private(set) var revealRequest: RevealRequest?

    struct RevealRequest: Equatable {
        let id = UUID()
        let url: URL
    }

    static let folderScanOptions = FolderScanOptions.default

    /// Mirrors `roots` (URLs only) and holds the add/lookup rules.
    private var workspace = WorkspaceRoots()
    /// One background scan session per root, keyed by root URL.
    private var rootSessions: [URL: FolderScanSession] = [:]
    /// One watcher per root. Stopped when the root is removed or goes
    /// missing, when the workspace is replaced or closed, and on deinit.
    nonisolated(unsafe) private var rootWatchers: [URL: FolderWatcher] = [:]
    /// A fresh workspace (or an add with nothing selected) selects a first
    /// file once the roots before it have finished scanning.
    private var pendingInitialSelection = false

    /// Resolves `[[wikilinks]]` across every root's notes and image assets.
    /// Rebuilt off the main thread (debounced) whenever a root's tree
    /// changes; nil with no workspace (opened-files mode), where wikilinks
    /// render as plain links.
    @Published private(set) var wikiLinkIndex: WikiLinkIndex?
    /// Bumped whenever `wikiLinkIndex` is replaced (the index itself isn't
    /// Equatable), so the preview knows to re-resolve its links.
    private(set) var wikiLinkIndexVersion = 0
    private var wikiLinkIndexTask: Task<Void, Never>?

    /// More than one root: the sidebar shows each as a top-level row.
    var isMultiRoot: Bool { roots.count > 1 }

    /// The workspace root that is or contains `url`, if any — for relative
    /// paths and the window subtitle.
    func workspaceRoot(containing url: URL) -> URL? {
        workspace.root(containing: url)
    }

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

    /// Set by any explicit open (Finder, Dock, panel, recents, drop) so the
    /// deferred last-folder restore never replaces it.
    private var hasOpenedDocument = false
    private var launchObserver: NSObjectProtocol?

    init() {
        readAloud.documentTitle = { [weak self] in self?.selectedFile?.name }
        readAloud.hotkeySource = { [weak self] in self?.readAloudHotkeySource() ?? .noDocument }
        readAloud.startHotkeyIntegration()
        loadRecents()
        Self.migrateLegacyBookmark()
        scheduleWorkspaceRestore()
    }

    deinit {
        for watcher in rootWatchers.values { watcher.stop() }
    }

    // MARK: – Open (file or folder)

    /// Shows an NSOpenPanel that accepts Markdown files and folders. Several
    /// files open together in the opened-files list; one or more folders
    /// open as the workspace. A mixed selection opens just the files.
    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose Markdown files, or a folder of Markdown files."
        panel.allowedContentTypes = MarkdownDocumentIO.markdownExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        openPanelSelection(panel.urls)
    }

    /// Routes an open-panel selection: one file replaces the document (as
    /// before), several files join the opened-files list with the first one
    /// selected, folders open as the workspace (one root each). Folders in a
    /// mixed selection are ignored.
    private func openPanelSelection(_ urls: [URL]) {
        var files: [URL] = []
        var folders: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue { folders.append(url) } else { files.append(url) }
        }
        switch (files.count, folders.count) {
        case (0, 0):
            return
        case (1, _):
            open(url: files[0])
        case (0, _):
            openFolders(folders)
        default:
            openDroppedFiles(files, selectingFirst: true)
        }
    }

    /// Opens `urls` (folders) as a new workspace, replacing the current one.
    /// Folders nested inside another of them are dropped. One folder goes
    /// through `open(url:)`; every opened folder is recorded in recents.
    func openFolders(_ urls: [URL]) {
        let folders = WorkspaceRoots.outermost(urls.filter(Self.isDirectory))
        if folders.count == 1 {
            open(url: folders[0])
            return
        }
        guard !folders.isEmpty else { return }
        hasOpenedDocument = true
        guard openWorkspace(folders) else { return }
        for folder in folders { addRecent(folder) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return url.isFileURL
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// The single rule for what PreviewMD opens: an existing Markdown file
    /// (by extension, see `MarkdownDocumentIO.markdownExtensions`), or — where
    /// allowed — a folder. Used by `open(url:)` and `openDroppedFiles(_:)`.
    static func canOpen(_ url: URL, allowingDirectories: Bool) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            return allowingDirectories
        }
        return MarkdownDocumentIO.isMarkdownFile(url)
    }

    /// Routes an arbitrary URL (from the open panel, `onOpenURL`, or Finder
    /// double-click of a single file) to the right loader. A single-file open
    /// hides the sidebar; a folder open replaces the workspace with that one
    /// folder and shows it. Nothing is recorded (recents, workspace bookmarks)
    /// if the user cancels the unsaved-changes prompt.
    func open(url: URL) {
        hasOpenedDocument = true
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            removeRecent(url)
            return
        }
        guard Self.canOpen(url, allowingDirectories: true) else {
            NSSound.beep()
            return
        }
        if isDir.boolValue {
            guard openWorkspace([url]) else { return }
        } else {
            guard openFile(at: url) else { return }
        }
        addRecent(url)
    }

    /// Follows a link from the previewed document to another Markdown file
    /// (a `[[wikilink]]` or a relative `[x](other.md)`). A file inside the
    /// open workspace is selected there — the workspace stays — after the
    /// unsaved-changes prompt; anything else goes through `open(url:)`.
    /// Returns true if `url` is now the selected file.
    @discardableResult
    func openLinkedFile(_ url: URL) -> Bool {
        let canonical = FileNode.canonicalURL(url)
        if selectedFile.map({ FileNode.canonicalURL($0.url) }) == canonical { return true }
        if sidebarMode == .folder,
           let root = workspace.root(containing: url),
           let treeURL = Self.treeURL(for: url, under: root),
           Self.canOpen(url, allowingDirectories: false) {
            guard confirmDiscardIfNeeded() else { return false }
            hasOpenedDocument = true
            selectFile(MarkdownFile(url: treeURL))
            addRecent(url)
            return true
        }
        open(url: url)
        return selectedFile.map { FileNode.canonicalURL($0.url) } == canonical
    }

    /// Opens a single Markdown file as the sole entry in the sidebar. Hides the
    /// sidebar by default — user can reveal it with ⌘⇧L. Returns false if the
    /// user cancelled the unsaved-changes prompt.
    @discardableResult
    func openFile(at url: URL) -> Bool {
        guard confirmDiscardIfNeeded() else { return false }
        closeWorkspace()
        sidebarMode = .openedFiles
        showSidebar = false
        let file = MarkdownFile(url: url)
        files = [file]
        selectFile(file)
        return true
    }

    /// Adds one or more files to the opened-files list. Used for drag-and-drop
    /// onto the window or Dock icon. Preserves existing entries, dedupes by
    /// standardized URL, and reveals the sidebar. With `selectingFirst` (the
    /// open panel) the first of `urls` becomes the selection; otherwise only
    /// an empty selection is filled.
    func openDroppedFiles(_ urls: [URL], selectingFirst: Bool = false) {
        let markdownURLs = urls
            .filter { Self.canOpen($0, allowingDirectories: false) }
            .map { $0.standardizedFileURL }
        guard !markdownURLs.isEmpty else { return }
        let switchesSelection = selectingFirst && selectedFile?.url.standardizedFileURL != markdownURLs[0]
        if switchesSelection {
            guard confirmDiscardIfNeeded() else { return }
        }
        hasOpenedDocument = true

        // Drops discard any previously-loaded workspace.
        if sidebarMode == .folder {
            closeWorkspace()
            files = []
            sidebarMode = .openedFiles
        }

        // Updated as we go so duplicates within the same drop are skipped too.
        var seen = Set(files.map { $0.url.standardizedFileURL })
        var firstNew: MarkdownFile?
        for url in markdownURLs {
            guard seen.insert(url).inserted else { continue }
            let file = MarkdownFile(url: url)
            files.append(file)
            if firstNew == nil { firstNew = file }
        }

        showSidebar = true

        if switchesSelection, let target = files.first(where: { $0.url.standardizedFileURL == markdownURLs[0] }) {
            selectFile(target)
        } else if selectedFile == nil, let target = firstNew ?? files.first {
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
        if wasSelected {
            guard confirmDiscardIfNeeded() else { return }
        }
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
        loadGeneration &+= 1 // drop any read still in flight
        isReadingFile = false
        isReadOnly = false
        isLoading = false
        selectedFile = nil
        setContent("")
        loadErrorMessage = nil
        loadedModificationDate = nil
        currentFormat = .utf8
        stopWatchingFile()
    }

    func toggleSidebar() {
        showSidebar.toggle()
    }

    /// Opens `url` as a one-folder workspace (see `openWorkspace`). Kept for
    /// existing callers. Returns false if the user cancelled the
    /// unsaved-changes prompt.
    @discardableResult
    func loadFolder(_ url: URL, preferredSelection: URL? = nil) -> Bool {
        openWorkspace([url], preferredSelection: preferredSelection)
    }

    /// Replaces the workspace with `urls` (in order; duplicates and folders
    /// nested inside an earlier one are dropped). Each root is scanned off
    /// the main thread (an iCloud vault can hold thousands of files) and
    /// watched for changes; the sidebar shows a loading state per root until
    /// its scan lands. Then the preferred file — or the first file of the
    /// first root that has one — is selected. Returns false if the user
    /// cancelled the unsaved-changes prompt (or `urls` held no folder).
    @discardableResult
    func openWorkspace(_ urls: [URL], preferredSelection: URL? = nil) -> Bool {
        let newWorkspace = WorkspaceRoots(urls)
        guard !newWorkspace.isEmpty else { return false }
        guard confirmDiscardIfNeeded() else { return false }
        hasOpenedDocument = true
        let sameRoots = newWorkspace == workspace
        closeWorkspace()
        if !sameRoots { expandedFolders = [] }
        workspace = newWorkspace
        roots = newWorkspace.roots.map { RootState(url: $0) }
        // Root rows (multi-root layout) start expanded.
        expandedFolders.formUnion(newWorkspace.roots)
        sidebarMode = .folder
        showSidebar = true
        files = []

        // A preferred file is known up front: show it while the scan runs.
        if let preferred = preferredSelection,
           let root = newWorkspace.root(containing: preferred),
           let treeURL = Self.treeURL(for: preferred, under: root),
           Self.canOpen(preferred, allowingDirectories: false) {
            selectFile(MarkdownFile(url: treeURL))
        } else {
            clearSelection()
            pendingInitialSelection = true
        }

        for root in newWorkspace.roots { startRoot(root) }
        persistWorkspace()
        return true
    }

    /// Appends `urls` (folders) to the workspace as new roots, expanded. A
    /// folder equal to, inside, or containing an existing root is not added;
    /// one alert names the clashing root(s). With no workspace open this
    /// opens one instead.
    func addFolders(_ urls: [URL]) {
        let folders = WorkspaceRoots.outermost(urls.filter(Self.isDirectory))
        guard !folders.isEmpty else { return }
        guard sidebarMode == .folder, !roots.isEmpty else {
            openFolders(folders)
            return
        }
        hasOpenedDocument = true
        var notices: [String] = []
        var added: [URL] = []
        for folder in folders {
            let name = "“\(folder.lastPathComponent)”"
            switch workspace.add(folder) {
            case .added:
                if let root = workspace.roots.last { added.append(root) }
            case .alreadyPresent:
                notices.append("\(name) is already in the workspace.")
            case .insideExisting(let root):
                notices.append("\(name) is inside “\(root.lastPathComponent)”, "
                    + "which is already in the workspace.")
            case .containsExisting(let existing):
                let names = ListFormatter.localizedString(
                    byJoining: existing.map { "“\($0.lastPathComponent)”" })
                let them = existing.count == 1 ? "it" : "them"
                notices.append("\(name) contains \(names), already in the workspace. "
                    + "Remove \(them) from the workspace first to add \(name).")
            }
        }
        if !added.isEmpty {
            // The current root keeps its (implicitly expanded) look when the
            // sidebar switches to the multi-root layout.
            expandedFolders.formUnion(roots.map(\.url))
            for root in added {
                roots.append(RootState(url: root))
                expandedFolders.insert(root)
                startRoot(root)
                addRecent(root)
            }
            showSidebar = true
            if selectedFile == nil { pendingInitialSelection = true }
            persistWorkspace()
        }
        if !notices.isEmpty {
            let alert = NSAlert()
            alert.messageText = notices.count == 1 && added.isEmpty
                ? "Folder not added" : "Some folders were not added"
            alert.informativeText = notices.joined(separator: "\n\n")
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    /// Shows an NSOpenPanel for folders only and adds the chosen ones to the
    /// workspace.
    func addFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to add to the workspace."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addFolders(panel.urls)
    }

    /// Removes root `url` from the workspace (nothing on disk changes). If
    /// the selected file is inside it, the unsaved-changes prompt runs first
    /// and the selection is cleared.
    func removeRoot(_ url: URL) {
        guard let index = workspace.index(of: url) else { return }
        let root = workspace.roots[index]
        let selectionInside = selectedFile.map {
            FileNode.relativeComponents(of: $0.url, under: root) != nil
        } ?? false
        if selectionInside {
            guard confirmDiscardIfNeeded() else { return }
        }
        workspace.remove(root)
        rootWatchers.removeValue(forKey: root)?.stop()
        rootSessions.removeValue(forKey: root)?.cancel()
        roots.removeAll { $0.url == root }
        expandedFolders = expandedFolders.filter {
            FileNode.relativeComponents(of: $0, under: root) == nil
        }
        if selectionInside { clearSelection() }
        if roots.isEmpty {
            sidebarMode = .openedFiles
            files = []
        } else {
            rebuildFiles()
        }
        scheduleWikiLinkIndexRebuild()
        persistWorkspace()
        selectInitialFileIfReady()
    }

    /// True if `url` is a workspace root or a folder in one of the trees: a
    /// sidebar row that expands and collapses rather than opens.
    func isFolderRow(_ url: URL) -> Bool {
        guard sidebarMode == .folder else { return false }
        if workspace.index(of: url) != nil { return true }
        guard let root = roots.first(where: { FileNode.relativeComponents(of: url, under: $0.url) != nil }),
              let node = root.tree?.node(at: url) else { return false }
        return node.isFolder
    }

    /// `url` rebuilt from `root` by name, so it equals the tree's own URL
    /// (tolerates `/private/var` vs `/var`); nil if outside `root`.
    private static func treeURL(for url: URL, under root: URL) -> URL? {
        guard let components = FileNode.relativeComponents(of: url, under: root),
              !components.isEmpty else { return nil }
        return components.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
    }

    /// Starts the scan session and watcher for one root.
    private func startRoot(_ root: URL) {
        let session = FolderScanSession(root: root, options: Self.folderScanOptions) {
            [weak self] session, update in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyFolderUpdate(update, from: session) }
            }
        }
        rootSessions[root] = session
        // Watch before scanning: changes made during the scan are picked up
        // by a refresh queued behind it.
        let watcher = FolderWatcher(root: root, queue: .main, latency: 0.3) {
            [weak self, weak session] event in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                self.handleFolderEvent(event, from: session)
            }
        }
        if watcher.start() { rootWatchers[root] = watcher }
        session.startInitialScan()
    }

    /// Tears down every root's tree, watcher and background session.
    /// Expansion state and the persisted workspace are left to the caller.
    private func closeWorkspace() {
        for watcher in rootWatchers.values { watcher.stop() }
        rootWatchers = [:]
        for session in rootSessions.values { session.cancel() }
        rootSessions = [:]
        roots = []
        workspace = WorkspaceRoots()
        pendingInitialSelection = false
        scheduleWikiLinkIndexRebuild()
    }

    /// Index in `roots` of the root `session` scans; nil once that root was
    /// removed, went missing, or the workspace was replaced.
    private func rootIndex(for session: FolderScanSession) -> Int? {
        guard let url = rootSessions.first(where: { $0.value === session })?.key else { return nil }
        return roots.firstIndex { $0.url == url }
    }

    private func applyFolderUpdate(_ update: FolderScanSession.Update, from session: FolderScanSession) {
        guard sidebarMode == .folder, let index = rootIndex(for: session) else { return }
        switch update {
        case .loaded(let tree):
            roots[index].isScanning = false
            publishTree(tree, at: index)
            if let selected = selectedFile {
                if workspace.root(containing: selected.url) == roots[index].url {
                    revealInTree(selected.url)
                }
            }
            selectInitialFileIfReady()
        case .changed(let tree):
            publishTree(tree, at: index)
        case .failed(let message):
            let root = roots[index].url
            roots[index].isScanning = false
            rootWatchers.removeValue(forKey: root)?.stop()
            presentError(
                title: "Could not open folder",
                message: "“\(session.root.lastPathComponent)” could not be read: \(message)")
            selectInitialFileIfReady()
        }
    }

    private func publishTree(_ tree: FolderTree, at index: Int) {
        guard tree != roots[index].tree else { return }
        roots[index].tree = tree
        rebuildFiles()
        scheduleWikiLinkIndexRebuild()
    }

    /// Rebuilds `wikiLinkIndex` from the current trees off the main thread,
    /// ~200 ms from now (at once for the first index, so a freshly opened
    /// workspace doesn't show its links unresolved); a newer call (another
    /// tree change) supersedes it. Called whenever the set of roots or any
    /// root's tree changes. With no trees, the index is cleared at once.
    private func scheduleWikiLinkIndexRebuild() {
        wikiLinkIndexTask?.cancel()
        wikiLinkIndexTask = nil
        let trees = sidebarMode == .folder ? roots.compactMap(\.tree) : []
        guard !trees.isEmpty else {
            setWikiLinkIndex(nil)
            return
        }
        let delay: UInt64 = wikiLinkIndex == nil ? 0 : 200_000_000
        wikiLinkIndexTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            let index = await Task.detached(priority: .userInitiated) {
                WikiLinkIndex(trees: trees)
            }.value
            guard !Task.isCancelled else { return }
            self?.setWikiLinkIndex(index)
        }
    }

    private func setWikiLinkIndex(_ index: WikiLinkIndex?) {
        if index == nil, wikiLinkIndex == nil { return }
        wikiLinkIndexVersion &+= 1
        wikiLinkIndex = index
    }

    /// `files` = every root's files in root order. Same URLs as the trees,
    /// so selection tags match sidebar rows.
    private func rebuildFiles() {
        files = roots.flatMap { $0.tree?.flatFiles ?? [] }.map(MarkdownFile.init(url:))
    }

    /// Fills an empty selection once it is deterministic: the first file of
    /// the first root (in order) that has one, waiting while an earlier root
    /// is still scanning.
    private func selectInitialFileIfReady() {
        guard pendingInitialSelection else { return }
        guard selectedFile == nil else {
            pendingInitialSelection = false
            return
        }
        for root in roots {
            if root.isScanning { return }
            if let tree = root.tree, let first = Self.initialFile(in: tree) {
                pendingInitialSelection = false
                selectFile(MarkdownFile(url: first))
                return
            }
        }
        pendingInitialSelection = false
    }

    /// The file a fresh folder opens on: the first one at the top level
    /// (a README, typically), else the first in display order.
    private static func initialFile(in tree: FolderTree) -> URL? {
        tree.root.children?.first(where: { !$0.isFolder })?.url ?? tree.flatFiles.first
    }

    private func handleFolderEvent(_ event: FolderWatcher.Event, from session: FolderScanSession) {
        guard let index = rootIndex(for: session) else { return }
        switch event {
        case .changed(let directories):
            session.refresh(directories)
        case .mustRescanAll:
            session.rescanAll()
        case .rootGone:
            // Only this root: keep its last tree and the open document (the
            // single-file watcher still tracks the document itself).
            let root = roots[index].url
            roots[index].isMissing = true
            roots[index].isScanning = false
            rootWatchers.removeValue(forKey: root)?.stop()
            session.cancel()
            rootSessions.removeValue(forKey: root)
            selectInitialFileIfReady()
        }
    }

    /// Expands the root row and folders above `url` (folder mode) and asks
    /// the sidebar to scroll to it.
    private func revealInTree(_ url: URL) {
        guard sidebarMode == .folder,
              let root = roots.first(where: { FileNode.relativeComponents(of: url, under: $0.url) != nil }),
              let tree = root.tree else { return }
        let toExpand = [root.url] + tree.ancestors(of: url)
        if !toExpand.allSatisfy(expandedFolders.contains) {
            expandedFolders.formUnion(toExpand)
        }
        revealRequest = RevealRequest(url: url)
    }

    func toggleExpanded(_ folder: URL) {
        if expandedFolders.contains(folder) {
            expandedFolders.remove(folder)
        } else {
            expandedFolders.insert(folder)
        }
    }

    /// Gate for anything that replaces the current document (open, folder load,
    /// remove). Returns true when it is safe to proceed: no unsaved edits, the
    /// user saved successfully, or chose not to save. The sidebar's own
    /// switch-file alert calls `selectFile` directly, so it never prompts twice.
    private func confirmDiscardIfNeeded() -> Bool {
        guard isDirty, let file = selectedFile else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(file.name)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveCurrentFile()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Back-compat shim for existing call sites that used the folder-only entry point.
    func openFolderPanel() { openPanel() }

    // MARK: – File selection

    /// What a background read produced for one file.
    private struct DiskSnapshot: @unchecked Sendable {
        let result: Result<MarkdownDocumentIO.Document, Error>
        let modificationDate: Date?
        let size: Int?

        var isLarge: Bool { (size ?? 0) > MarkdownDocumentIO.largeFileThreshold }
    }

    /// Reads off the main thread: an iCloud-evicted file blocks until it is
    /// downloaded, which must not hang the UI.
    private nonisolated static func readSnapshot(
        of url: URL, preferring preferred: MarkdownDocumentIO.Format? = nil
    ) async -> DiskSnapshot {
        await Task.detached(priority: .userInitiated) {
            let result = Result { try MarkdownDocumentIO.read(from: url, preferring: preferred) }
            return DiskSnapshot(
                result: result,
                modificationDate: modificationDate(of: url),
                size: MarkdownDocumentIO.fileSize(of: url))
        }.value
    }

    /// Sets both the editor buffer and the clean snapshot (never dirty).
    private func setContent(_ text: String) {
        savedContent = text
        editingContent = text
    }

    func selectFile(_ file: MarkdownFile) {
        loadGeneration &+= 1
        let generation = loadGeneration
        stopWatchingFile()
        isLoading = true
        isReadingFile = true
        isReadOnly = false
        loadErrorMessage = nil
        selectedFile = files.first(where: { $0 == file }) ?? file
        revealInTree(file.url)
        // Show the loading state rather than the previous file's text.
        setContent("")

        let url = file.url
        Task { [weak self] in
            let snapshot = await Self.readSnapshot(of: url)
            self?.finishLoading(snapshot, url: url, generation: generation)
        }
    }

    private func finishLoading(_ snapshot: DiskSnapshot, url: URL, generation: Int) {
        // A newer selection started while this read was in flight.
        guard generation == loadGeneration else { return }
        isReadingFile = false

        switch snapshot.result {
        case .success(let document):
            currentFormat = document.format
            loadedModificationDate = snapshot.modificationDate
            isReadOnly = snapshot.isLarge
            if isReadOnly, viewMode == .edit {
                // The plain editor is unusable at this size; show the preview.
                viewMode = .preview
            }
            setContent(document.text)
            if isReadOnly {
                notifyOpenedReadOnly(name: url.lastPathComponent, size: snapshot.size ?? 0)
            }
        case .failure(let error):
            currentFormat = .utf8
            loadedModificationDate = nil
            loadErrorMessage = error.localizedDescription
            setContent("")
            isLoading = false
            return
        }
        watchFile(at: url)

        // isLoading stays true until MarkdownPreviewView reports the render is
        // complete via `markPreviewRendered()`. For the Edit-only view mode there
        // is no preview — flip the flag on the next runloop tick so the spinner
        // doesn't get stuck if the user switched modes.
        if viewMode == .edit {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.isLoading = false
            }
        } else {
            // Safety timeout: if the preview pipeline never calls back (view
            // not mounted yet, navigation stalls, etc.), force-clear so the
            // spinner doesn't strand the UI.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.isLoading = false
            }
        }
    }

    /// Called by `MarkdownPreviewView` once the WebView has finished rendering
    /// the current markdown text. Clears the loading state — unless the file
    /// is still being read, in which case the render was of the placeholder.
    func markPreviewRendered() {
        guard !isReadingFile else { return }
        if isLoading { isLoading = false }
    }

    // MARK: – Saving

    /// Saves the current file. Returns true when the file was written (used by
    /// the quit guard to decide whether termination may proceed).
    @discardableResult
    func saveCurrentFile() -> Bool {
        guard let file = selectedFile else { return false }
        guard loadErrorMessage == nil, !isReadingFile, !isReadOnly else { return false }

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
            try MarkdownDocumentIO.write(editingContent, to: file.url, format: currentFormat)
        } catch MarkdownDocumentIO.WriteError.unencodable {
            // Content no longer representable in the file's original encoding
            // (e.g. emoji added to a Latin-1 file). Line endings are kept.
            let alert = NSAlert()
            alert.messageText = "Could not save in the file's original encoding"
            alert.informativeText = "“\(file.name)” contains characters that can't be represented in "
                + "\(String.localizedName(of: currentFormat.encoding)).\n\nSave as UTF-8 instead?"
            alert.addButton(withTitle: "Save as UTF-8")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            let utf8 = MarkdownDocumentIO.Format(encoding: .utf8, lineEnding: currentFormat.lineEnding)
            do {
                try MarkdownDocumentIO.write(editingContent, to: file.url, format: utf8)
                currentFormat = utf8
            } catch {
                presentError(title: "Could not save file", message: error.localizedDescription)
                return false
            }
        } catch {
            presentError(title: "Could not save file", message: error.localizedDescription)
            return false
        }

        savedContent = editingContent
        loadedModificationDate = modificationDate(of: file.url)
        return true
    }

    private func modificationDate(of url: URL) -> Date? {
        Self.modificationDate(of: url)
    }

    private nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Shown once per open of a file above the size limit. A sheet when a
    /// window is available so it doesn't block the rest of the app.
    private func notifyOpenedReadOnly(name: String, size: Int) {
        let alert = NSAlert()
        alert.messageText = "“\(name)” opened read-only"
        alert.informativeText = "This file is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)). "
            + "Editing and saving are turned off for files over "
            + "\(ByteCountFormatter.string(fromByteCount: Int64(MarkdownDocumentIO.largeFileThreshold), countStyle: .file)) "
            + "to keep PreviewMD responsive. Use another editor to change it."
        alert.alertStyle = .informational
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: – External change watching

    /// Watches the selected file for writes by other processes. `FileWatcher`
    /// follows the path across atomic saves and delete/recreate, so this is
    /// armed once per selection.
    private func watchFile(at url: URL) {
        stopWatchingFile()
        let watcher = FileWatcher(url: url, queue: .main) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleExternalChange(event, at: url)
            }
        }
        watcher.start()
        fileWatcher = watcher
    }

    private func stopWatchingFile() {
        fileWatcher?.stop()
        fileWatcher = nil
    }

    private func handleExternalChange(_ event: FileWatcher.Event, at url: URL) {
        guard selectedFile?.url.standardizedFileURL == url.standardizedFileURL else { return }
        // Deleted: keep the buffer so the user can re-save (the save path
        // recreates the file). The watcher keeps looking for it to reappear.
        guard event == .modified else { return }
        // Our own save (or a no-op touch): nothing to reload. Re-reading here
        // would also re-run encoding detection on our own bytes.
        let onDisk = modificationDate(of: url)
        if let loaded = loadedModificationDate, onDisk == loaded { return }

        if isDirty {
            notifyChangedOnDisk(url: url)
        } else {
            reloadFromDisk(url: url)
        }
    }

    /// Re-reads the selected file in the background and applies it if the
    /// selection is unchanged and the buffer is still clean.
    private func reloadFromDisk(url: URL) {
        let generation = loadGeneration
        let preferred = currentFormat
        Task { [weak self] in
            let snapshot = await Self.readSnapshot(of: url, preferring: preferred)
            guard let self, generation == self.loadGeneration, !self.isDirty,
                  case .success(let document) = snapshot.result else { return }
            self.currentFormat = document.format
            self.loadedModificationDate = snapshot.modificationDate
            self.isReadOnly = self.isReadOnly || snapshot.isLarge
            if document.text != self.savedContent {
                self.setContent(document.text)
            }
        }
    }

    /// The file changed on disk while the buffer has unsaved edits: ask
    /// instead of silently keeping (and later clobbering) either version.
    private func notifyChangedOnDisk(url: URL) {
        guard !isShowingChangedOnDiskAlert, let file = selectedFile else { return }
        isShowingChangedOnDiskAlert = true
        let alert = NSAlert()
        alert.messageText = "“\(file.name)” changed on disk"
        alert.informativeText = "Another application modified this file while you have unsaved edits. "
            + "Reload to discard your edits and show the version on disk, or keep your edits — "
            + "saving will then overwrite the version on disk."
        alert.addButton(withTitle: "Keep My Edits")
        alert.addButton(withTitle: "Reload")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.isShowingChangedOnDiskAlert = false
            guard self.selectedFile?.url.standardizedFileURL == url.standardizedFileURL else { return }
            if response == .alertSecondButtonReturn {
                self.savedContent = self.editingContent // drop the dirty flag; reload replaces both
                self.loadedModificationDate = nil
                self.reloadFromDisk(url: url)
            } else {
                // Acknowledged: the next ⌘S overwrites without asking again.
                self.loadedModificationDate = self.modificationDate(of: url)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { handle(response) }
            }
        } else {
            handle(alert.runModal())
        }
    }

    // MARK: – Workspace restore

    // The app is not sandboxed, so plain bookmarks (which survive renames
    // and moves) are all that's needed — no security scope.

    /// Saves the current roots, in order; clears the key when there are none.
    private func persistWorkspace() {
        let defaults = UserDefaults.standard
        guard !workspace.isEmpty else {
            defaults.removeObject(forKey: kWorkspaceBookmarksKey)
            return
        }
        defaults.set(WorkspaceBookmarks.encode(workspace.roots), forKey: kWorkspaceBookmarksKey)
    }

    private static var storedWorkspaceBookmarks: [Data] {
        UserDefaults.standard.array(forKey: kWorkspaceBookmarksKey) as? [Data] ?? []
    }

    /// One-time move of the single-folder bookmark into the workspace key.
    private static func migrateLegacyBookmark() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.data(forKey: kLegacyBookmarkKey) else { return }
        if defaults.object(forKey: kWorkspaceBookmarksKey) == nil {
            defaults.set([legacy], forKey: kWorkspaceBookmarksKey)
        }
        defaults.removeObject(forKey: kLegacyBookmarkKey)
    }

    /// Reopens the last workspace once launch has finished — but only if
    /// launch didn't open something itself (Finder double-click, Dock drop,
    /// `open`), which would otherwise be clobbered or flash the folders first.
    private func scheduleWorkspaceRestore() {
        guard !Self.storedWorkspaceBookmarks.isEmpty else { return }
        let deferRestore = { [weak self] in
            // Launch-time opens are delivered asynchronously after the window
            // appears; give them a beat to land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.restoreWorkspaceIfIdle() }
            }
        }
        if NSRunningApplication.current.isFinishedLaunching {
            deferRestore()
        } else {
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let observer = self?.launchObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self?.launchObserver = nil
                    }
                }
                deferRestore()
            }
        }
    }

    private func restoreWorkspaceIfIdle() {
        guard !hasOpenedDocument, selectedFile == nil, files.isEmpty, roots.isEmpty else { return }
        // Roots that are gone, not folders, or unreadable (e.g. permission
        // denied) are skipped quietly instead of alerting on every launch.
        let urls = WorkspaceBookmarks.resolve(Self.storedWorkspaceBookmarks)
        guard !urls.isEmpty else {
            UserDefaults.standard.removeObject(forKey: kWorkspaceBookmarksKey)
            return
        }
        // Re-persists the surviving roots (refreshing stale bookmarks).
        openWorkspace(urls)
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

// MARK: – Folder scanning

/// The background half of folder mode: owns a working copy of one opened
/// folder's tree on a private serial queue. Watcher events are coalesced and
/// applied there (`FolderTree.refresh`), and a new tree is handed to
/// `publish` only when it actually changed — so our own saves, which touch
/// the folder but not its listing, never republish.
///
/// One session per workspace root; the owner drops results from a session
/// it no longer holds. `cancel()` stops further work (an in-flight scan still
/// finishes, but its result is not delivered).
private final class FolderScanSession: @unchecked Sendable {

    enum Update: Sendable {
        /// The first scan finished.
        case loaded(FolderTree)
        /// A refresh or rescan changed the tree.
        case changed(FolderTree)
        /// The root could not be listed.
        case failed(String)
    }

    let root: URL
    let options: FolderScanOptions
    private let queue: DispatchQueue
    private let publish: @Sendable (FolderScanSession, Update) -> Void

    /// Confined to `queue`.
    private var tree: FolderTree?

    private let lock = NSLock()
    // Guarded by `lock`.
    private var pendingDirectories: [URL] = []
    private var pendingRescanAll = false
    private var drainScheduled = false
    private var cancelled = false

    init(root: URL, options: FolderScanOptions,
         publish: @escaping @Sendable (FolderScanSession, Update) -> Void) {
        self.root = root
        self.options = options
        self.publish = publish
        // Per session, so a slow scan of the previous folder never delays
        // this one.
        self.queue = DispatchQueue(label: "PreviewMD.folder-scan", qos: .userInitiated)
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        pendingDirectories = []
        pendingRescanAll = false
    }

    func startInitialScan() {
        queue.async { [self] in
            guard !isCancelled else { return }
            do {
                _ = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            } catch {
                deliver(.failed(error.localizedDescription))
                return
            }
            let scanned = FolderTree(scanning: root, options: options)
            tree = scanned
            deliver(.loaded(scanned))
        }
    }

    func refresh(_ directories: [URL]) {
        schedule { $0.pendingDirectories.append(contentsOf: directories) }
    }

    func rescanAll() {
        schedule { $0.pendingRescanAll = true }
    }

    private func schedule(_ record: (FolderScanSession) -> Void) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        record(self)
        let needsDrain = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if needsDrain { queue.async { [self] in drain() } }
    }

    /// Applies everything recorded since the last drain in one pass.
    private func drain() {
        lock.lock()
        let directories = pendingDirectories
        let rescanAll = pendingRescanAll
        pendingDirectories = []
        pendingRescanAll = false
        drainScheduled = false
        let stop = cancelled
        lock.unlock()
        guard !stop else { return }

        if rescanAll || tree == nil {
            let scanned = FolderTree(scanning: root, options: options)
            guard scanned != tree else { return }
            let isFirst = tree == nil
            tree = scanned
            deliver(isFirst ? .loaded(scanned) : .changed(scanned))
            return
        }
        guard var working = tree else { return }
        var changed = false
        var seen: Set<String> = []
        for directory in directories where seen.insert(directory.path).inserted {
            if working.refresh(directory: directory, options: options) { changed = true }
        }
        guard changed else { return }
        tree = working
        deliver(.changed(working))
    }

    private func deliver(_ update: Update) {
        guard !isCancelled else { return }
        publish(self, update)
    }
}
