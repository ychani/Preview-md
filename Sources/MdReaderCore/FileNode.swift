import Foundation

/// One entry in the folder explorer: a Markdown file, or a folder that
/// (transitively) contains at least one.
///
/// URLs are kept in a canonical form (see `canonicalURL(_:)`): standardized,
/// no trailing slash, built from the scanned root by appending names. All
/// tree lookups canonicalize their input, so callers may pass URLs from an
/// open panel, a drop, or FSEvents without normalizing them first.
public struct FileNode: Identifiable, Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        case file
        case folder
    }

    public let url: URL
    public let name: String
    public let kind: Kind
    /// Sorted (folders first, then Finder order). Always non-nil for folders,
    /// nil for files.
    public var children: [FileNode]?

    public var id: URL { url }
    public var isFolder: Bool { kind == .folder }

    public init(url: URL, kind: Kind, children: [FileNode]? = nil) {
        let canonical = Self.canonicalURL(url)
        self.url = canonical
        self.name = canonical.lastPathComponent
        self.kind = kind
        self.children = kind == .folder ? Self.sorted(children ?? []) : nil
    }

    /// Internal fast path: `url` is already canonical and `children` already
    /// sorted (the scanner builds nodes in display order).
    init(canonicalURL url: URL, kind: Kind, sortedChildren: [FileNode]?) {
        self.url = url
        self.name = url.lastPathComponent
        self.kind = kind
        self.children = kind == .folder ? (sortedChildren ?? []) : nil
    }

    // MARK: - Ordering

    /// Finder-like order: folders before files, then `localizedStandardCompare`
    /// ("file2" before "file10", case-insensitive). Ties fall back to a
    /// literal comparison so the order is total and deterministic.
    public static func areInIncreasingOrder(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.kind != b.kind { return a.kind == .folder }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.name < b.name
        }
    }

    public static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted(by: areInIncreasingOrder)
    }

    // MARK: - URL canonicalization

    /// The form every node URL takes: standardized file URL (`.`/`..`
    /// removed, `/private` dropped where Foundation does so), no trailing slash.
    public static func canonicalURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false)
    }

    /// Path components of `url` below `root` (empty when they are the same
    /// directory), or nil if `url` is not inside `root`. Tolerates the
    /// `/private/var` vs `/var` (and `/private/tmp` vs `/tmp`) split that
    /// FSEvents, `realpath` and Foundation disagree on.
    public static func relativeComponents(of url: URL, under root: URL) -> [String]? {
        let rootPaths = pathVariants(canonicalURL(root).path)
        let path = canonicalURL(url).path
        for rootPath in rootPaths {
            for candidate in pathVariants(path) {
                if candidate == rootPath { return [] }
                let prefix = rootPath == "/" ? "/" : rootPath + "/"
                if candidate.hasPrefix(prefix) {
                    return candidate.dropFirst(prefix.count)
                        .split(separator: "/", omittingEmptySubsequences: true)
                        .map(String.init)
                }
            }
        }
        return nil
    }

    /// `realpath(3)`: fully resolved (symlinks followed, `/private` kept).
    /// Nil if the path, or a symlink's target, does not exist.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` plus its `/private`-prefixed or -stripped twin, if any.
    static func pathVariants(_ path: String) -> [String] {
        if path.hasPrefix("/private/") {
            return [path, String(path.dropFirst("/private".count))]
        }
        if path.hasPrefix("/var/") || path == "/var" || path.hasPrefix("/tmp/") || path == "/tmp"
            || path.hasPrefix("/etc/") {
            return [path, "/private" + path]
        }
        return [path]
    }
}

extension URL {
    /// `appendingPathComponent` without the filesystem probe: Foundation
    /// otherwise stats the result and adds a trailing slash for directories,
    /// which would make the same folder compare unequal depending on timing.
    func appendingNodeComponent(_ name: String) -> URL {
        appendingPathComponent(name, isDirectory: false)
    }
}
