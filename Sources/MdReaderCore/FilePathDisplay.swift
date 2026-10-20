import Foundation

/// Path strings for the explorer UI: tooltips, quick-open rows, and tab
/// titles that need a hint when two open files share a name.
public enum FilePathDisplay {

    /// `url`'s path relative to `root` ("notes/today.md"). Empty when `url`
    /// is `root`; the `~`-abbreviated full path when it is outside `root`.
    public static func relativePath(of url: URL, in root: URL) -> String {
        if let components = FileNode.relativeComponents(of: url, under: root) {
            return components.joined(separator: "/")
        }
        return abbreviated(FileNode.canonicalURL(url).path)
    }

    /// The folder containing `url`, with the home directory shown as `~`
    /// ("~/Documents/notes"; "~" for a file directly in home; "/" at the top).
    public static func abbreviatedParent(
        of url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let parent = FileNode.canonicalURL(url).deletingLastPathComponent().path
        return abbreviated(parent, home: home)
    }

    /// For each URL, the secondary label that tells it apart from others with
    /// the same file name: the shortest trailing part of its parent path that
    /// differs from theirs ("a" vs "b", or "src/x" vs "lib/x"), falling back to
    /// the full `~`-abbreviated parent. `nil` when the name is unique.
    public static func disambiguatedNames(
        _ urls: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL: String?] {
        var result: [URL: String?] = [:]
        var groups: [String: [URL]] = [:]
        var canonicalOf: [URL: URL] = [:]
        for url in urls where canonicalOf[url] == nil {
            let canonical = FileNode.canonicalURL(url)
            canonicalOf[url] = canonical
            groups[canonical.lastPathComponent, default: []].append(url)
        }
        for (_, members) in groups {
            // Distinct files only: two spellings of one path are not rivals.
            var parents: [URL: String] = [:]
            for url in members {
                parents[url] = canonicalOf[url]!.deletingLastPathComponent().path
            }
            let distinctParents = Set(parents.values)
            guard distinctParents.count > 1 else {
                for url in members { result[url] = .some(nil) }
                continue
            }
            for url in members {
                let mine = parents[url]!
                let others = distinctParents.subtracting([mine])
                result[url] = .some(shortestDistinguishingSuffix(of: mine, from: others, home: home))
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func shortestDistinguishingSuffix(
        of parent: String, from others: Set<String>, home: URL
    ) -> String {
        let mine = parent.split(separator: "/").map(String.init)
        let theirs = others.map { $0.split(separator: "/").map(String.init) }
        for k in 1...max(mine.count, 1) {
            let label = suffixLabel(mine, k, fullPath: parent, home: home)
            let clashes = zip(others, theirs).contains { otherPath, otherComponents in
                suffixLabel(otherComponents, k, fullPath: otherPath, home: home) == label
            }
            if !clashes { return label }
        }
        return abbreviated(parent, home: home)
    }

    /// The last `k` components joined, or the full abbreviated path when
    /// `k` reaches the whole path.
    private static func suffixLabel(_ components: [String], _ k: Int, fullPath: String,
                                    home: URL) -> String {
        k >= components.count
            ? abbreviated(fullPath, home: home)
            : components.suffix(k).joined(separator: "/")
    }

    private static func abbreviated(
        _ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let homePath = FileNode.canonicalURL(home).path
        guard homePath != "/" else { return path }
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
