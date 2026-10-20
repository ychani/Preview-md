import AppKit
import MdReaderCore

/// Finder / pasteboard actions for a file's location, shared by the File menu
/// (and usable from sidebar context menus).
@MainActor
enum FileLocationActions {

    /// Opens a Finder window with `url` selected (Finder's "Reveal").
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url.standardizedFileURL])
    }

    /// Puts `url`'s absolute POSIX path on the pasteboard, like Finder's
    /// "Copy as Pathname".
    static func copyPath(_ url: URL) {
        copyString(url.standardizedFileURL.path)
    }

    /// Puts `url`'s path relative to `root` ("notes/today.md") on the
    /// pasteboard; the `~`-abbreviated full path when `url` is outside `root`.
    static func copyRelativePath(_ url: URL, root: URL) {
        copyString(FilePathDisplay.relativePath(of: url, in: root))
    }

    /// Window subtitle for the selected file: in folder mode the folder name
    /// plus the file's folder path inside it ("notes › 2026"; just "notes" for
    /// a root-level file); otherwise the `~`-abbreviated parent folder.
    static func locationSubtitle(for url: URL, folderRoot: URL?) -> String {
        guard let root = folderRoot,
              FileNode.relativeComponents(of: url, under: root) != nil else {
            return FilePathDisplay.abbreviatedParent(of: url)
        }
        let rootName = FileNode.canonicalURL(root).lastPathComponent
        let relativeFolder = FilePathDisplay.relativePath(
            of: url.deletingLastPathComponent(), in: root)
        let components = relativeFolder.split(separator: "/").map(String.init)
        return ([rootName] + components).joined(separator: " › ")
    }

    private static func copyString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
