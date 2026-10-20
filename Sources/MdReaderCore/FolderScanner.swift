import Foundation

/// What the folder explorer shows, and how far it looks.
public struct FolderScanOptions: Equatable, Sendable {
    /// Lowercased file extensions that count as Markdown.
    public var extensions: Set<String>
    /// Directory names never descended into (in addition to hidden ones).
    public var ignoredDirectoryNames: Set<String>
    /// Skip dot-files and Finder-hidden items — covers `.git`, `.obsidian`,
    /// `.trash`, and iCloud `.name.icloud` placeholders.
    public var skipHidden: Bool
    /// Descend into symbolic links that point at directories. Off by default:
    /// links can escape the folder or form cycles.
    public var followSymlinkedDirectories: Bool
    /// Deepest level shown; the root's own entries are level 1. A folder at
    /// level `maxDepth` or deeper is not descended into.
    public var maxDepth: Int
    /// Most Markdown files a scan collects before stopping (`truncated`).
    public var maxFiles: Int
    /// Lowercased extensions of asset files (images) collected alongside the
    /// Markdown files — for wikilink embeds — into `ScanResult.assetFiles`.
    /// Assets never appear in the tree and never keep a folder from being
    /// pruned. Empty disables asset collection.
    public var assetExtensions: Set<String>
    /// Most asset files a scan collects (`assetsTruncated`). Independent of
    /// `maxFiles`.
    public var maxAssetFiles: Int

    /// Image types collected as assets by default.
    public static let defaultAssetExtensions: Set<String> = [
        "png", "apng", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "avif",
        "bmp", "tif", "tiff",
    ]

    public init(
        extensions: Set<String> = MarkdownDocumentIO.markdownExtensions,
        ignoredDirectoryNames: Set<String> = ["node_modules"],
        skipHidden: Bool = true,
        followSymlinkedDirectories: Bool = false,
        maxDepth: Int = 16,
        maxFiles: Int = 20_000,
        assetExtensions: Set<String> = FolderScanOptions.defaultAssetExtensions,
        maxAssetFiles: Int = 20_000
    ) {
        self.extensions = Set(extensions.map { $0.lowercased() })
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.skipHidden = skipHidden
        self.followSymlinkedDirectories = followSymlinkedDirectories
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.assetExtensions = Set(assetExtensions.map { $0.lowercased() })
        self.maxAssetFiles = maxAssetFiles
    }

    public static let `default` = FolderScanOptions()

    func isMarkdownName(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }

    func isAssetName(_ name: String) -> Bool {
        !assetExtensions.isEmpty
            && assetExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// Builds the folder explorer's tree from disk. Reads directory metadata only
/// — never file contents — so iCloud-evicted files are listed without being
/// downloaded. Folders with no Markdown descendants are pruned.
///
/// Image assets (`FolderScanOptions.assetExtensions`) under the same skip
/// rules are listed separately in `ScanResult.assetFiles`, sorted by path;
/// they are not tree nodes. Once the Markdown cap is hit the walk stops, so
/// assets past that point are not collected either.
///
/// Synchronous; run it off the main thread for large folders.
public enum FolderScanner {

    public struct ScanResult: Equatable, Sendable {
        public let root: FileNode
        /// True if `maxFiles` was reached and some files were left out.
        public let truncated: Bool
        /// Image assets found during the scan (canonical URLs, sorted by path).
        public let assetFiles: [URL]
        /// True if `maxAssetFiles` was reached and some assets were left out.
        public let assetsTruncated: Bool

        public init(root: FileNode, truncated: Bool,
                    assetFiles: [URL] = [], assetsTruncated: Bool = false) {
            self.root = root
            self.truncated = truncated
            self.assetFiles = assetFiles
            self.assetsTruncated = assetsTruncated
        }
    }

    /// Scans `root` recursively. The root node is always returned (possibly
    /// with no children). When the cap is hit the files kept are the first
    /// `maxFiles` in display order.
    public static func scan(_ root: URL, options: FolderScanOptions = .default) -> ScanResult {
        let rootURL = FileNode.canonicalURL(root)
        let walker = Walker(options: options, budget: options.maxFiles)
        walker.enter(rootURL)
        let children = walker.children(of: rootURL, level: 0)
        return ScanResult(
            root: FileNode(canonicalURL: rootURL, kind: .folder, sortedChildren: children),
            truncated: walker.truncated,
            assetFiles: walker.sortedAssets(),
            assetsTruncated: walker.assetsTruncated)
    }

    /// Rebuilds the (pruned, sorted) children of `directory`, a folder inside
    /// `root` (or `root` itself), honoring the same options as `scan`. Returns
    /// an empty array if the directory is gone, outside `root`, or excluded
    /// (hidden, ignored, symlinked, too deep). `budget` caps the files
    /// collected — pass what remains of `maxFiles` after the rest of the tree;
    /// defaults to `options.maxFiles`.
    public static func rescan(
        directory: URL, root: URL, options: FolderScanOptions = .default, budget: Int? = nil
    ) -> [FileNode] {
        rescanReportingTruncation(directory: directory, root: root, options: options,
                                  budget: budget).children
    }

    struct RescanResult {
        var children: [FileNode]
        var truncated: Bool
        /// Assets inside `directory`, sorted by path.
        var assetFiles: [URL] = []
        var assetsTruncated = false
    }

    static func rescanReportingTruncation(
        directory: URL, root: URL, options: FolderScanOptions, budget: Int?,
        assetBudget: Int? = nil
    ) -> RescanResult {
        let rootURL = FileNode.canonicalURL(root)
        guard let components = FileNode.relativeComponents(of: directory, under: rootURL),
              components.count < max(options.maxDepth, 1) else {
            return RescanResult(children: [], truncated: false)
        }
        // Rebuild the directory URL from the root so it matches tree URLs.
        let dirURL = components.reduce(rootURL) { $0.appendingNodeComponent($1) }
        let walker = Walker(options: options, budget: max(budget ?? options.maxFiles, 0),
                            assetBudget: max(assetBudget ?? options.maxAssetFiles, 0))

        // Every folder from the root down to `directory` must be one the full
        // scan would have descended into.
        var current = rootURL
        walker.enter(rootURL)
        for name in components {
            current = current.appendingNodeComponent(name)
            guard let entry = Walker.entry(for: current), walker.shouldDescend(entry) else {
                return RescanResult(children: [], truncated: false)
            }
            walker.enter(current)
        }
        let children = walker.children(of: dirURL, level: components.count)
        return RescanResult(children: children, truncated: walker.truncated,
                            assetFiles: walker.sortedAssets(),
                            assetsTruncated: walker.assetsTruncated)
    }

    // MARK: - Walker

    /// One scan's mutable state: remaining file budget, truncation, and the
    /// real paths of the folders currently being walked (symlink cycle guard).
    final class Walker {
        let options: FolderScanOptions
        var budget: Int
        var truncated = false
        var assetBudget: Int
        var assetsTruncated = false
        private(set) var assets: [URL] = []
        private var activeRealPaths: Set<String> = []

        static let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey,
        ]

        struct Entry {
            let url: URL
            let name: String
            let isDirectory: Bool
            let isSymlink: Bool
            let isPackage: Bool
            let isHidden: Bool
        }

        init(options: FolderScanOptions, budget: Int, assetBudget: Int? = nil) {
            self.options = options
            self.budget = budget
            self.assetBudget = assetBudget ?? options.maxAssetFiles
        }

        func sortedAssets() -> [URL] {
            assets.sorted { $0.path < $1.path }
        }

        func enter(_ url: URL) {
            activeRealPaths.insert(Self.realPath(url) ?? url.path)
        }

        /// Metadata for one directory entry, following a symlink only to learn
        /// whether its target is a directory.
        static func entry(for url: URL) -> Entry? {
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
            let isSymlink = values.isSymbolicLink ?? false
            var isDirectory = values.isDirectory ?? false
            var isPackage = values.isPackage ?? false
            if isSymlink {
                // realpath fails for a dangling link; drop those.
                guard let real = realPath(url),
                      let targetValues = try? URL(fileURLWithPath: real).resourceValues(
                        forKeys: [.isDirectoryKey, .isPackageKey]) else { return nil }
                isDirectory = targetValues.isDirectory ?? false
                isPackage = targetValues.isPackage ?? false
            }
            return Entry(url: url, name: url.lastPathComponent, isDirectory: isDirectory,
                         isSymlink: isSymlink, isPackage: isPackage,
                         isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."))
        }

        func shouldDescend(_ entry: Entry) -> Bool {
            guard entry.isDirectory, !entry.isPackage else { return false }
            if options.skipHidden && (entry.isHidden || entry.name.hasPrefix(".")) { return false }
            if options.ignoredDirectoryNames.contains(entry.name) { return false }
            if entry.isSymlink {
                guard options.followSymlinkedDirectories else { return false }
                // Cycle guard: a link back to a folder we are inside.
                if let real = Self.realPath(entry.url), activeRealPaths.contains(real) { return false }
            }
            return true
        }

        /// Pruned, sorted children of `dir`, which sits at `level` (root = 0).
        func children(of dir: URL, level: Int) -> [FileNode] {
            guard !truncated else { return [] }
            let listOptions: FileManager.DirectoryEnumerationOptions =
                options.skipHidden ? [.skipsHiddenFiles] : []
            let urls: [URL]
            if let listed = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Self.resourceKeys, options: listOptions) {
                urls = listed
            } else if let real = Self.realPath(dir), real != dir.path,
                      let listed = try? FileManager.default.contentsOfDirectory(
                        at: URL(fileURLWithPath: real, isDirectory: true),
                        includingPropertiesForKeys: Self.resourceKeys, options: listOptions) {
                // The URL API won't list *through* a final symlink component
                // (ENOTDIR); list its target instead. Child URLs below are
                // still built from `dir`, so they keep the link's path.
                urls = listed
            } else {
                urls = []
            }

            // Classify, then walk in display order so a truncated scan keeps
            // a prefix of what the user would see.
            var candidates: [FileNode] = []
            var folderEntries: [URL: Entry] = [:]
            for url in urls {
                let name = url.lastPathComponent
                // Rebuild from the canonical parent: contentsOfDirectory may
                // hand back resolved (`/private/...`) URLs.
                let childURL = dir.appendingNodeComponent(name)
                guard let entry = Self.entry(for: url) else { continue }
                if entry.isDirectory {
                    guard level + 1 < options.maxDepth, shouldDescend(entry) else { continue }
                    folderEntries[childURL] = entry
                    candidates.append(FileNode(canonicalURL: childURL, kind: .folder, sortedChildren: []))
                } else if options.isMarkdownName(name) {
                    if options.skipHidden && entry.isHidden { continue }
                    candidates.append(FileNode(canonicalURL: childURL, kind: .file, sortedChildren: nil))
                } else if options.isAssetName(name) {
                    if options.skipHidden && entry.isHidden { continue }
                    if assetBudget > 0 {
                        assetBudget -= 1
                        assets.append(childURL)
                    } else {
                        assetsTruncated = true
                    }
                }
            }
            candidates.sort(by: FileNode.areInIncreasingOrder)

            var result: [FileNode] = []
            result.reserveCapacity(candidates.count)
            for candidate in candidates {
                if candidate.kind == .folder {
                    let real = folderEntries[candidate.url].flatMap { Self.realPath($0.url) }
                    if let real { activeRealPaths.insert(real) }
                    let kids = children(of: candidate.url, level: level + 1)
                    if let real { activeRealPaths.remove(real) }
                    if !kids.isEmpty {
                        result.append(FileNode(canonicalURL: candidate.url, kind: .folder,
                                               sortedChildren: kids))
                    }
                } else {
                    guard budget > 0 else {
                        truncated = true
                        break
                    }
                    budget -= 1
                    result.append(candidate)
                }
                if truncated { break }
            }
            return result
        }

        static func realPath(_ url: URL) -> String? { FileNode.realPath(url) }
    }
}
