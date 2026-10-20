import AppKit
import MdReaderCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showUnsavedAlert = false
    @State private var pendingFile: MarkdownFile?
    /// A folder row highlighted by keyboard navigation. Files stay the real
    /// selection (`appState.selectedFile`); this only moves the highlight.
    @State private var highlightedFolder: URL?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if appState.sidebarMode == .folder, appState.isFolderMissing {
                notice(icon: "exclamationmark.triangle", text: "Folder was moved or deleted")
            }
            if appState.sidebarMode == .folder, appState.folderTree?.isTruncated == true {
                notice(icon: "exclamationmark.triangle",
                       text: "Showing first \(Self.formattedFileCap) files")
            }

            if appState.sidebarMode == .folder, appState.isScanningFolder {
                Spacer()
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning folder…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
            } else if appState.files.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.quaternary)
                        .accessibilityHidden(true)
                    Text("No Markdown files")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                fileList
            }
        }
        .frame(minWidth: 180)
        .onChange(of: appState.selectedFile?.id) { _ in
            highlightedFolder = nil
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
            Button("Save", role: .none) {
                if appState.saveCurrentFile(), let f = pendingFile { appState.selectFile(f) }
                pendingFile = nil
            }
            Button("Discard", role: .destructive) {
                if let f = pendingFile { appState.selectFile(f) }
                pendingFile = nil
            }
            Button("Cancel", role: .cancel) {
                pendingFile = nil
            }
        } message: {
            Text("Do you want to save your changes to \"\(appState.selectedFile?.name ?? "")\" before switching files?")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            if appState.sidebarMode == .folder, let folder = appState.folderURL {
                Image(systemName: appState.isFolderMissing ? "folder.badge.questionmark" : "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(folder.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                    .contextMenu {
                        PathMenuItems(url: folder, root: nil)
                    }
            } else {
                Text("FILES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.8)
            }
            Spacer()
            Button {
                appState.openPanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Open file or folder…")
            .accessibilityLabel("Open File or Folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func notice(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private static let formattedFileCap: String = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let cap = AppState.folderScanOptions.maxFiles
        return formatter.string(from: NSNumber(value: cap)) ?? String(cap)
    }()

    // MARK: - List

    private var fileList: some View {
        ScrollViewReader { proxy in
            // Selection is the single source of truth for both mouse clicks
            // and keyboard (arrow-key) navigation. No row-level
            // onTapGesture: it swallowed clicks and, combined with the
            // selection setter, could fire attemptSelect twice per click.
            List(selection: selection) {
                if appState.sidebarMode == .folder, let tree = appState.folderTree {
                    ForEach(tree.root.children ?? []) { node in
                        TreeNodeRow(
                            node: node,
                            root: tree.rootURL,
                            selectedURL: appState.selectedFile?.id,
                            highlightedFolder: highlightedFolder,
                            expandedFolders: $appState.expandedFolders)
                    }
                } else {
                    let details = FilePathDisplay.disambiguatedNames(appState.files.map(\.url))
                    ForEach(appState.files) { file in
                        let disambiguator = details[file.url].flatMap { $0 }
                        FileRowView(
                            file: file,
                            isSelected: appState.selectedFile?.id == file.id,
                            detail: disambiguator ?? FilePathDisplay.abbreviatedParent(of: file.url),
                            detailIsDisambiguator: disambiguator != nil)
                            .tag(file.id)
                            .contextMenu {
                                PathMenuItems(url: file.url, root: nil)
                                if appState.sidebarMode == .openedFiles {
                                    Divider()
                                    Button("Remove from List") {
                                        appState.removeFromList(file)
                                    }
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: appState.revealRequest) { request in
                guard let url = request?.url else { return }
                // Let newly expanded folders lay out their rows first.
                DispatchQueue.main.async {
                    proxy.scrollTo(url)
                }
            }
        }
    }

    /// Clicks and arrow keys both arrive here. Files go through the dirty
    /// guard; a folder row is highlighted, and a mouse click on it also
    /// toggles it open or closed (as in VS Code's explorer).
    private var selection: Binding<URL?> {
        Binding(
            get: { highlightedFolder ?? appState.selectedFile?.id },
            set: { newID in
                guard let id = newID else { return }
                if appState.sidebarMode == .folder, let tree = appState.folderTree,
                   let node = tree.node(at: id), node.isFolder {
                    if Self.isMouseEvent {
                        appState.toggleExpanded(node.url)
                        highlightedFolder = nil
                    } else {
                        highlightedFolder = node.url
                    }
                    return
                }
                highlightedFolder = nil
                guard let file = appState.files.first(where: { $0.id == id }),
                      file != appState.selectedFile else { return }
                attemptSelect(file)
            }
        )
    }

    private static var isMouseEvent: Bool {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return true
        default: return false
        }
    }

    private func attemptSelect(_ file: MarkdownFile) {
        if appState.isDirty {
            pendingFile = file
            showUnsavedAlert = true
        } else {
            appState.selectFile(file)
        }
    }
}

// MARK: - Tree

/// One node of the folder tree: a file row, or a folder as a
/// `DisclosureGroup` whose children are built only while it is expanded.
private struct TreeNodeRow: View {
    let node: FileNode
    let root: URL
    let selectedURL: URL?
    let highlightedFolder: URL?
    @Binding var expandedFolders: Set<URL>

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: isExpanded) {
                if isExpanded.wrappedValue {
                    ForEach(node.children ?? []) { child in
                        TreeNodeRow(node: child, root: root, selectedURL: selectedURL,
                                    highlightedFolder: highlightedFolder,
                                    expandedFolders: $expandedFolders)
                    }
                }
            } label: {
                FolderRowView(name: node.name, path: node.url.path,
                              isExpanded: isExpanded.wrappedValue,
                              isHighlighted: highlightedFolder == node.url)
                    .contextMenu {
                        PathMenuItems(url: node.url, root: root)
                    }
            }
            .tag(node.url)
        } else {
            FileRowView(file: MarkdownFile(url: node.url),
                        isSelected: selectedURL == node.url,
                        detail: nil, detailIsDisambiguator: false)
                .tag(node.url)
                .contextMenu {
                    PathMenuItems(url: node.url, root: root)
                }
        }
    }

    private var isExpanded: Binding<Bool> {
        let url = node.url
        return Binding(
            get: { expandedFolders.contains(url) },
            set: { expand in
                if expand { expandedFolders.insert(url) } else { expandedFolders.remove(url) }
            })
    }
}

private struct FolderRowView: View {
    let name: String
    let path: String
    let isExpanded: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 1)
        .help(path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folder, \(name)")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }
}

// MARK: - File row

private struct FileRowView: View {
    let file: MarkdownFile
    let isSelected: Bool
    /// Dimmed text after the name: the parent folder in the opened-files
    /// list, or what tells two same-named files apart.
    let detail: String?
    let detailIsDisambiguator: Bool

    private var displayName: String {
        file.name.hasSuffix(".md")
            ? String(file.name.dropLast(3))
            : file.name
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            Text(displayName)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(detailIsDisambiguator ? .secondary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 1)
        .help(file.url.path)
        // One element per row, announced by full file name (the visible text
        // may be extension-stripped or middle-truncated) plus selection state.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(file.name)
        .accessibilityHint(detail.map { "in \($0)" } ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Location actions

/// "Reveal in Finder" / "Copy Path" (/ "Copy Relative Path" when `root` is
/// the open folder) for a file or folder row's context menu.
private struct PathMenuItems: View {
    let url: URL
    let root: URL?

    var body: some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Button("Copy Path") {
            copyToPasteboard(url.path)
        }
        if let root {
            Button("Copy Relative Path") {
                copyToPasteboard(FilePathDisplay.relativePath(of: url, in: root))
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
