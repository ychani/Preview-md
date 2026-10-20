import Foundation

// MARK: - WikiLink

/// One Obsidian-style wikilink: `[[target#heading|alias]]`, or an embed
/// `![[target]]`.
public struct WikiLink: Hashable, Sendable {
    /// The link target as written, trimmed: `note`, `folder/note`,
    /// `note.md`, `pic.png`. Empty only for a same-document heading link
    /// (`[[#Heading]]`), which never resolves to a file.
    public var target: String
    /// Text after the first `#` (heading or `^block` reference), trimmed;
    /// nil when absent or empty.
    public var heading: String?
    /// Text after the first `|`, trimmed; nil when absent or empty.
    public var alias: String?
    /// True for `![[...]]` embeds.
    public var isEmbed: Bool

    public init(target: String, heading: String? = nil, alias: String? = nil, isEmbed: Bool = false) {
        self.target = target
        self.heading = heading
        self.alias = alias
        self.isEmbed = isEmbed
    }

    /// Parses the text of one wikilink.
    ///
    /// `raw` is the inner text of `[[...]]` (`note#h|alias`). A leading `!`
    /// marks an embed (`!pic.png`); the surrounding brackets are tolerated
    /// too (`[[note]]`, `![[pic.png]]`). The first `|` starts the alias and
    /// the first `#` before it starts the heading; a `\` right before the `|`
    /// (Obsidian's escape inside tables) is dropped. Every part is trimmed.
    ///
    /// Returns nil for an empty link (`[[]]`, `[[ | x]]`) or one spanning lines.
    public static func parse(_ raw: String) -> WikiLink? {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces))
        var isEmbed = false
        if text.hasPrefix("!") {
            isEmbed = true
            text = text.dropFirst()
        }
        if text.hasPrefix("[["), text.hasSuffix("]]"), text.count >= 4 {
            text = text.dropFirst(2).dropLast(2)
        }
        guard !text.contains(where: \.isNewline) else { return nil }

        var left = text
        var alias: String?
        if let bar = text.firstIndex(of: "|") {
            left = text[..<bar]
            if left.hasSuffix("\\") { left = left.dropLast() }
            alias = trimmedNonEmpty(text[text.index(after: bar)...])
        }
        var targetPart = left
        var heading: String?
        if let hash = left.firstIndex(of: "#") {
            targetPart = left[..<hash]
            heading = trimmedNonEmpty(left[left.index(after: hash)...])
        }
        let target = targetPart.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty || heading != nil else { return nil }
        return WikiLink(target: target, heading: heading, alias: alias, isEmbed: isEmbed)
    }

    /// `target` without a trailing `.md` (any case) — the form used to match
    /// note names, since `[[note]]` and `[[note.md]]` mean the same file.
    public var matchTarget: String {
        Self.strippingMarkdownSuffix(target)
    }

    /// The keys a `[[...]]` link is looked up by in the preview's wikilink
    /// map: `target`, plus `target#heading` (the text before `|`, trimmed)
    /// when there is a heading.
    public var lookupKeys: [String] {
        guard !target.isEmpty else { return [] }
        guard let heading else { return [target] }
        return [target, "\(target)#\(heading)"]
    }

    // MARK: Scanning a document

    /// Every wikilink in `markdown`, in document order, skipping fenced code
    /// blocks (``` and ~~~) and inline code spans. Approximate: links and
    /// code spans are recognized within a single line only.
    public static func links(in markdown: String) -> [WikiLink] {
        var result: [WikiLink] = []
        var fence: (char: UInt8, length: Int)?
        for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let bytes = Array(line.utf8)
            if let marker = fenceMarker(bytes) {
                if let open = fence {
                    // A closing fence: same character, at least as long, nothing after.
                    if marker.char == open.char, marker.length >= open.length, marker.isBare {
                        fence = nil
                    }
                } else {
                    fence = (marker.char, marker.length)
                }
                continue
            }
            if fence != nil { continue }
            scanLine(bytes, into: &result)
        }
        return result
    }

    /// The raw targets (`WikiLink.target`, as written) of every wikilink in
    /// `markdown`, skipping code. Same-document heading links are left out.
    public static func targets(in markdown: String) -> Set<String> {
        Set(links(in: markdown).lazy.map(\.target).filter { !$0.isEmpty })
    }

    // MARK: Internals

    static func strippingMarkdownSuffix(_ s: String) -> String {
        guard s.count > 3, s.lowercased().hasSuffix(".md") else { return s }
        return String(s.dropLast(3))
    }

    private static func trimmedNonEmpty(_ s: Substring) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private static let backtick = UInt8(ascii: "`")
    private static let tilde = UInt8(ascii: "~")
    private static let space = UInt8(ascii: " ")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")
    private static let bang = UInt8(ascii: "!")

    /// A code-fence line: up to three spaces, then 3+ backticks or tildes.
    private static func fenceMarker(_ b: [UInt8]) -> (char: UInt8, length: Int, isBare: Bool)? {
        var i = 0
        while i < b.count, i < 3, b[i] == space { i += 1 }
        guard i < b.count, b[i] == backtick || b[i] == tilde else { return nil }
        let char = b[i]
        var j = i
        while j < b.count, b[j] == char { j += 1 }
        let length = j - i
        guard length >= 3 else { return nil }
        let rest = b[j...]
        // A backtick fence's info string may not contain backticks.
        if char == backtick, rest.contains(backtick) { return nil }
        let isBare = rest.allSatisfy { $0 == space || $0 == UInt8(ascii: "\t") }
        return (char, length, isBare)
    }

    private static func scanLine(_ b: [UInt8], into result: inout [WikiLink]) {
        var i = 0
        let n = b.count
        while i < n {
            if b[i] == backtick {
                // Inline code: a run of N backticks closed by the next run of exactly N.
                var j = i
                while j < n, b[j] == backtick { j += 1 }
                let runLength = j - i
                var k = j
                var closeEnd: Int?
                while k < n {
                    if b[k] == backtick {
                        var m = k
                        while m < n, b[m] == backtick { m += 1 }
                        if m - k == runLength { closeEnd = m; break }
                        k = m
                    } else {
                        k += 1
                    }
                }
                // Unclosed backticks are literal text.
                i = closeEnd ?? j
                continue
            }
            if b[i] == openBracket, i + 1 < n, b[i + 1] == openBracket {
                let start = i + 2
                var k = start
                var end: Int?
                while k + 1 < n {
                    if b[k] == closeBracket, b[k + 1] == closeBracket { end = k; break }
                    if b[k] == openBracket, b[k + 1] == openBracket { break }  // `[[a [[b]]`
                    k += 1
                }
                if let end {
                    let isEmbed = i > 0 && b[i - 1] == bang
                    if let inner = String(bytes: b[start..<end], encoding: .utf8),
                       var link = parse(inner) {
                        link.isEmbed = isEmbed
                        result.append(link)
                    }
                    i = end + 2
                    continue
                }
                i = k > start ? k : start
                continue
            }
            i += 1
        }
    }
}

// MARK: - Resolution

/// Where a wikilink points.
public struct WikiLinkResolution: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case note
        case image
    }

    /// The target file (canonical, as in `FolderTree`).
    public let url: URL
    public let kind: Kind
    /// The workspace root that contains `url`.
    public let rootURL: URL
    /// `url`'s path below `rootURL`, POSIX (`folder/note.md`).
    public let relativePath: String

    public init(url: URL, kind: Kind, rootURL: URL, relativePath: String) {
        self.url = url
        self.kind = kind
        self.rootURL = rootURL
        self.relativePath = relativePath
    }
}

/// Resolves wikilinks against the notes (`FolderTree.flatFiles`) and image
/// assets (`FolderTree.assetFiles`) of one or more workspace roots.
///
/// Building is O(n) in the number of files; lookups touch only the files
/// sharing the target's basename. An immutable value: rebuild it whenever a
/// tree changes.
public struct WikiLinkIndex: Sendable {

    struct Entry: Sendable {
        let url: URL
        let kind: WikiLinkResolution.Kind
        let rootIndex: Int
        /// Root-relative path as on disk.
        let relativePath: String
        /// Lowercased root-relative path, and the same without the extension
        /// (notes only; equal to `relLower` for images).
        let relLower: String
        let relStemLower: String
        /// Path of the containing folder (absolute, canonical).
        let parentPath: String
        let componentCount: Int
    }

    private let roots: [URL]
    private var entries: [Entry] = []
    /// Lowercased basename → entries. Notes are keyed with and without
    /// their extension; images only with it.
    private var notesByName: [String: [Int]] = [:]
    private var imagesByName: [String: [Int]] = [:]

    /// Lowercased image extensions the index treats as image targets.
    public static let imageExtensions: Set<String> = FolderScanOptions.defaultAssetExtensions

    public init(trees: [FolderTree]) {
        roots = trees.map(\.rootURL)
        var count = 0
        for tree in trees { count += tree.flatFiles.count + tree.assetFiles.count }
        entries.reserveCapacity(count)
        for (rootIndex, tree) in trees.enumerated() {
            let rootPath = tree.rootURL.path
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            for url in tree.flatFiles { add(url, kind: .note, rootIndex: rootIndex, rootPrefix: prefix) }
            for url in tree.assetFiles { add(url, kind: .image, rootIndex: rootIndex, rootPrefix: prefix) }
        }
    }

    /// Number of indexed files (notes + images).
    public var count: Int { entries.count }

    private mutating func add(_ url: URL, kind: WikiLinkResolution.Kind, rootIndex: Int, rootPrefix: String) {
        let path = url.path
        guard path.hasPrefix(rootPrefix) else { return }
        let rel = String(path.dropFirst(rootPrefix.count))
        guard !rel.isEmpty else { return }
        let relLower = rel.lowercased()

        let slash = relLower.lastIndex(of: "/")
        let nameLower = slash.map { String(relLower[relLower.index(after: $0)...]) } ?? relLower
        var stemLower = nameLower
        var relStemLower = relLower
        if kind == .note, let dot = nameLower.lastIndex(of: "."), dot != nameLower.startIndex {
            stemLower = String(nameLower[..<dot])
            relStemLower = String(relLower.dropLast(nameLower.distance(from: dot, to: nameLower.endIndex)))
        }
        let parentPath = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        var components = 1
        for byte in rel.utf8 where byte == UInt8(ascii: "/") { components += 1 }

        let index = entries.count
        entries.append(Entry(url: url, kind: kind, rootIndex: rootIndex, relativePath: rel,
                             relLower: relLower, relStemLower: relStemLower,
                             parentPath: parentPath, componentCount: components))
        switch kind {
        case .note:
            notesByName[nameLower, default: []].append(index)
            if stemLower != nameLower { notesByName[stemLower, default: []].append(index) }
        case .image:
            imagesByName[nameLower, default: []].append(index)
        }
    }

    /// Resolves `link` as seen from the note at `documentURL`, or nil.
    ///
    /// A target with an image extension matches image assets; anything else
    /// matches notes, with `.md` implied (`[[note]]` = `[[note.md]]`). A
    /// target containing `/` must match the end of a root-relative path
    /// (`[[folder/note]]` matches `a/folder/note.md`); a leading `/` anchors
    /// it at the root, and `./` / `../` resolve against the document's folder.
    /// Matching ignores case.
    ///
    /// Among several matches (Obsidian-like): an exact root-relative path
    /// match wins; then a file in the document's own folder; then one in the
    /// document's own workspace root; then the shortest path (fewest
    /// components); then alphabetical by relative path, for determinism.
    public func resolve(_ link: WikiLink, from documentURL: URL) -> WikiLinkResolution? {
        var target = link.target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let documentURL = FileNode.canonicalURL(documentURL)
        let documentFolder = documentURL.deletingLastPathComponent().path

        // Path-relative targets: turn them into an anchored root-relative path.
        var anchored = false
        if target.hasPrefix("./") || target.hasPrefix("../") {
            let absolute = FileNode.canonicalURL(
                URL(fileURLWithPath: documentFolder).appendingPathComponent(target)).path
            guard let (_, rel) = rootRelative(absolute) else { return nil }
            target = rel
            anchored = true
        } else if target.hasPrefix("/") {
            target = String(target.drop(while: { $0 == "/" }))
            anchored = true
        }
        guard !target.isEmpty else { return nil }

        let lower = target.lowercased()
        let nameLower = lower.lastIndex(of: "/").map { String(lower[lower.index(after: $0)...]) } ?? lower
        let ext = (nameLower as NSString).pathExtension
        let isImage = Self.imageExtensions.contains(ext)
        let candidates: [Int]
        let wanted: String
        if isImage {
            candidates = imagesByName[nameLower] ?? []
            wanted = lower
        } else {
            let key = WikiLink.strippingMarkdownSuffix(nameLower)
            candidates = notesByName[key] ?? []
            wanted = WikiLink.strippingMarkdownSuffix(lower)
        }
        guard !candidates.isEmpty else { return nil }
        let suffix = "/" + wanted
        let documentRoot = rootRelative(documentURL.path)?.rootIndex

        var best: (index: Int, rank: (Int, Int, Int, Int))?
        for i in candidates {
            let e = entries[i]
            let exact = e.relStemLower == wanted || e.relLower == wanted
            if anchored {
                guard exact else { continue }
            } else {
                guard exact || e.relStemLower.hasSuffix(suffix) || e.relLower.hasSuffix(suffix) else {
                    continue
                }
            }
            let rank = (exact ? 0 : 1,
                        e.parentPath == documentFolder ? 0 : 1,
                        e.rootIndex == documentRoot ? 0 : 1,
                        e.componentCount)
            if let current = best {
                if rank < current.rank { best = (i, rank) }
                else if rank == current.rank, isAlphabeticallyBefore(e, entries[current.index]) {
                    best = (i, rank)
                }
            } else {
                best = (i, rank)
            }
        }
        guard let winner = best.map({ entries[$0.index] }) else { return nil }
        return WikiLinkResolution(url: winner.url, kind: winner.kind,
                                  rootURL: roots[winner.rootIndex], relativePath: winner.relativePath)
    }

    /// Resolves every wikilink in `markdown` (code skipped) into the map the
    /// preview expects: each of a link's `lookupKeys` → its resolution.
    /// Unresolved links are left out.
    public func resolutions(in markdown: String, from documentURL: URL) -> [String: WikiLinkResolution] {
        var map: [String: WikiLinkResolution] = [:]
        var unresolved: Set<String> = []
        for link in WikiLink.links(in: markdown) {
            let keys = link.lookupKeys
            guard let first = keys.first, map[first] == nil, !unresolved.contains(first) else {
                // Target already settled; still record the `target#heading` key.
                if let first = keys.first, let known = map[first] {
                    for key in keys.dropFirst() { map[key] = known }
                }
                continue
            }
            if let resolution = resolve(link, from: documentURL) {
                for key in keys { map[key] = resolution }
            } else {
                unresolved.insert(first)
            }
        }
        return map
    }

    private func isAlphabeticallyBefore(_ a: Entry, _ b: Entry) -> Bool {
        if a.relLower != b.relLower { return a.relLower < b.relLower }
        if a.relativePath != b.relativePath { return a.relativePath < b.relativePath }
        return a.rootIndex < b.rootIndex
    }

    /// The root containing absolute `path` and the path below it.
    private func rootRelative(_ path: String) -> (rootIndex: Int, relative: String)? {
        for (i, root) in roots.enumerated() {
            if let components = FileNode.relativeComponents(of: URL(fileURLWithPath: path), under: root),
               !components.isEmpty {
                return (i, components.joined(separator: "/"))
            }
        }
        return nil
    }
}
