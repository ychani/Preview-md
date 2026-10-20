import Foundation

/// The folder explorer's model: the scanned tree plus derived lookups.
/// A value type — mutate a copy off the main thread and publish it whole.
///
/// URL arguments are canonicalized (`FileNode.canonicalURL`), so trailing
/// slashes and `/private/var` vs `/var` don't matter.
public struct FolderTree: Equatable, Sendable {

    public private(set) var root: FileNode
    /// Every file, in display order (depth-first, folders before files) —
    /// what "next / previous file" and quick-open walk.
    public private(set) var flatFiles: [URL]
    /// True if the scan (or a later refresh) hit `maxFiles`. A full rescan
    /// (`init(scanning:options:)`) is the only thing that clears it.
    public var isTruncated: Bool

    private var allURLs: Set<URL>

    public init(root: FileNode, isTruncated: Bool = false) {
        self.root = root
        self.isTruncated = isTruncated
        self.flatFiles = []
        self.allURLs = []
        rebuildIndex()
    }

    /// Scans `url` from disk (synchronous).
    public init(scanning url: URL, options: FolderScanOptions = .default) {
        let result = FolderScanner.scan(url, options: options)
        self.init(root: result.root, isTruncated: result.truncated)
    }

    public var rootURL: URL { root.url }

    // MARK: - Queries

    /// True if `url` is the root or any file/folder node in the tree.
    public func contains(_ url: URL) -> Bool {
        guard let canonical = canonicalInTree(url) else { return false }
        return allURLs.contains(canonical)
    }

    /// The folders between the root (exclusive) and `url` (exclusive), top
    /// down — the folders to expand to reveal `url`. Empty if `url` is a
    /// direct child of the root, the root itself, or outside the tree.
    public func ancestors(of url: URL) -> [URL] {
        guard let components = FileNode.relativeComponents(of: url, under: root.url),
              components.count > 1 else { return [] }
        var result: [URL] = []
        var current = root.url
        for name in components.dropLast() {
            current = current.appendingNodeComponent(name)
            result.append(current)
        }
        return result
    }

    /// The node at `url`, if it is in the tree.
    public func node(at url: URL) -> FileNode? {
        guard let components = FileNode.relativeComponents(of: url, under: root.url) else {
            return nil
        }
        var node = root
        for name in components {
            guard let next = node.children?.first(where: { $0.name == name }) else { return nil }
            node = next
        }
        return node
    }

    // MARK: - Mutation

    /// Replaces the children of folder `dir` (the root or any folder below
    /// it) with `children` — typically `FolderScanner.rescan(directory:…)`.
    ///
    /// - A folder not yet in the tree is inserted, with any missing parent
    ///   folders, if `children` is non-empty.
    /// - A folder left empty is removed, as are parents it leaves empty
    ///   (the root itself always stays).
    /// - Sibling subtrees are untouched.
    public mutating func replaceChildren(of dir: URL, with children: [FileNode]) {
        guard let components = FileNode.relativeComponents(of: dir, under: root.url) else { return }
        let sortedChildren = FileNode.sorted(children)
        let newRoot = Self.replacing(in: root, path: components[...], with: sortedChildren)
        // `replacing` returns nil only when a non-root folder ends up empty.
        let updated = newRoot ?? FileNode(canonicalURL: root.url, kind: .folder, sortedChildren: [])
        guard updated != root else { return }
        root = updated
        rebuildIndex()
    }

    /// Rescans folder `dir` from disk and splices the result in, keeping the
    /// file cap: the rescan may use whatever `maxFiles` leaves after the
    /// files outside `dir`. Returns true if the tree changed.
    @discardableResult
    public mutating func refresh(directory dir: URL, options: FolderScanOptions = .default) -> Bool {
        guard let components = FileNode.relativeComponents(of: dir, under: root.url) else {
            return false
        }
        let dirURL = components.reduce(root.url) { $0.appendingNodeComponent($1) }
        let dirPrefix = components.isEmpty ? nil : dirURL.path + "/"
        let filesInside = dirPrefix.map { prefix in flatFiles.lazy.filter { $0.path.hasPrefix(prefix) }.count }
            ?? flatFiles.count
        let budget = options.maxFiles - (flatFiles.count - filesInside)
        let result = FolderScanner.rescanReportingTruncation(
            directory: dirURL, root: root.url, options: options, budget: budget)
        let before = self
        replaceChildren(of: dirURL, with: result.children)
        if result.truncated { isTruncated = true }
        return self != before
    }

    // MARK: - Internals

    /// Returns `node` with the folder at `path` (relative to it) given
    /// `children`, or nil if `node` should be removed because it is a
    /// non-root folder left with no children.
    private static func replacing(
        in node: FileNode, path: ArraySlice<String>, with children: [FileNode]
    ) -> FileNode? {
        guard let name = path.first else {
            return children.isEmpty
                ? nil
                : FileNode(canonicalURL: node.url, kind: .folder, sortedChildren: children)
        }
        var kids = node.children ?? []
        let index = kids.firstIndex(where: { $0.name == name })
        let existing: FileNode
        if let index, kids[index].kind == .folder {
            existing = kids[index]
        } else {
            // Nothing to remove, and nothing to add.
            if children.isEmpty { return node }
            // New folder (or a file replaced by a folder of the same name).
            existing = FileNode(canonicalURL: node.url.appendingNodeComponent(name),
                                kind: .folder, sortedChildren: [])
        }
        let replaced = replacing(in: existing, path: path.dropFirst(), with: children)
        if let index { kids.remove(at: index) }
        if let replaced {
            let insertAt = kids.firstIndex(where: { FileNode.areInIncreasingOrder(replaced, $0) })
                ?? kids.endIndex
            kids.insert(replaced, at: insertAt)
        }
        return kids.isEmpty
            ? nil
            : FileNode(canonicalURL: node.url, kind: .folder, sortedChildren: kids)
    }

    private func canonicalInTree(_ url: URL) -> URL? {
        guard let components = FileNode.relativeComponents(of: url, under: root.url) else {
            return nil
        }
        return components.reduce(root.url) { $0.appendingNodeComponent($1) }
    }

    private mutating func rebuildIndex() {
        var files: [URL] = []
        var all: Set<URL> = []
        func visit(_ node: FileNode) {
            all.insert(node.url)
            switch node.kind {
            case .file: files.append(node.url)
            case .folder: node.children?.forEach(visit)
            }
        }
        visit(root)
        flatFiles = files
        allURLs = all
    }
}
