import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

private let kBookmarkKey = "FolderSecurityBookmark"

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

    var isDirty: Bool { editingContent != savedContent }

    init() {
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
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            saveBookmark(for: url)
            loadFolder(url)
        } else {
            openFile(at: url)
        }
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
}
