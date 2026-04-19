import AppKit
import Combine
import Foundation

private let kBookmarkKey = "FolderSecurityBookmark"

@MainActor
final class AppState: ObservableObject {
    @Published var folderURL: URL?
    @Published var files: [MarkdownFile] = []
    @Published var selectedFile: MarkdownFile?
    @Published var viewMode: ViewMode = .preview
    @Published var isDirty: Bool = false

    // Editable text for the currently open file
    @Published var editingContent: String = ""

    init() {
        restoreBookmark()
    }

    // MARK: – Folder

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url)
        loadFolder(url)
    }

    func loadFolder(_ url: URL) {
        folderURL = url
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)
            files = contents
                .filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
                .map { fileURL in
                    let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                    return MarkdownFile(url: fileURL, content: text)
                }
        } catch {
            files = []
        }
        if let first = files.first {
            selectFile(first)
        } else {
            selectedFile = nil
            editingContent = ""
            isDirty = false
        }
    }

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
        isDirty = false
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
            isDirty = false
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
