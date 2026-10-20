import Foundation

/// The folders open in the sidebar, VS Code "multi-root workspace" style:
/// an ordered list of canonical root URLs, none equal to, inside, or
/// containing another (so every file belongs to at most one root).
///
/// URL arguments are canonicalized (`FileNode.canonicalURL`); comparisons
/// tolerate trailing slashes and the `/private/var` vs `/var` split.
public struct WorkspaceRoots: Equatable, Sendable {

    /// What `add(_:)` did with a folder.
    public enum AddOutcome: Equatable, Sendable {
        /// Appended as a new root.
        case added
        /// Already a root; nothing changed.
        case alreadyPresent
        /// Rejected: inside this existing root.
        case insideExisting(URL)
        /// Rejected: contains these existing roots (in root order).
        case containsExisting([URL])
    }

    public private(set) var roots: [URL]

    /// Adds `urls` in order, dropping any that `add(_:)` would reject.
    public init(_ urls: [URL] = []) {
        roots = []
        for url in urls { add(url) }
    }

    public var isEmpty: Bool { roots.isEmpty }

    /// Appends `url` as a root unless it equals, is inside, or contains an
    /// existing root — the owner-approved rule is to reject, not merge.
    @discardableResult
    public mutating func add(_ url: URL) -> AddOutcome {
        let candidate = FileNode.canonicalURL(url)
        for root in roots {
            if let components = FileNode.relativeComponents(of: candidate, under: root) {
                return components.isEmpty ? .alreadyPresent : .insideExisting(root)
            }
        }
        let contained = roots.filter { FileNode.relativeComponents(of: $0, under: candidate) != nil }
        if !contained.isEmpty { return .containsExisting(contained) }
        roots.append(candidate)
        return .added
    }

    /// Removes the root equal to `url`. Returns false if `url` is not a root.
    @discardableResult
    public mutating func remove(_ url: URL) -> Bool {
        guard let index = index(of: url) else { return false }
        roots.remove(at: index)
        return true
    }

    /// The root that is `url` or contains it, if any.
    public func root(containing url: URL) -> URL? {
        roots.first { FileNode.relativeComponents(of: url, under: $0) != nil }
    }

    /// Position of the root equal to `url` (not merely containing it).
    public func index(of url: URL) -> Int? {
        roots.firstIndex { FileNode.relativeComponents(of: url, under: $0) == [] }
    }

    /// `urls` without those equal to or nested inside another of them,
    /// order kept — what a multi-folder open keeps from a panel selection.
    public static func outermost(_ urls: [URL]) -> [URL] {
        let canonical = urls.map(FileNode.canonicalURL)
        var kept: [URL] = []
        for (index, url) in canonical.enumerated() {
            let covered = canonical.enumerated().contains { other in
                guard other.offset != index,
                      let components = FileNode.relativeComponents(of: url, under: other.element)
                else { return false }
                // Inside another, or a duplicate of an earlier one.
                return !components.isEmpty || other.offset < index
            }
            if !covered { kept.append(url) }
        }
        return kept
    }
}

/// Persists workspace roots as plain bookmarks (the app is not sandboxed),
/// which survive renames and moves of the folders.
public enum WorkspaceBookmarks {

    /// One bookmark per URL that can be bookmarked, in order.
    public static func encode(_ urls: [URL]) -> [Data] {
        urls.compactMap {
            try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    /// The folders `bookmarks` still point to, in order. Bookmarks that no
    /// longer resolve, or resolve to something that is not a readable
    /// folder, are dropped.
    public static func resolve(_ bookmarks: [Data]) -> [URL] {
        bookmarks.compactMap { data in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data, options: [.withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            else { return nil }
            // A bookmark follows a folder into the Trash; treat that as gone.
            guard !url.standardizedFileURL.path.contains("/.Trash/") else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) != nil
            else { return nil }
            return FileNode.canonicalURL(url)
        }
    }
}
