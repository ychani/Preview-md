import XCTest
@testable import MdReaderCore

final class WikiLinkParseTests: XCTestCase {

    func testPlainTarget() {
        XCTAssertEqual(WikiLink.parse("a"), WikiLink(target: "a"))
    }

    func testAlias() {
        XCTAssertEqual(WikiLink.parse("a|b"), WikiLink(target: "a", alias: "b"))
    }

    func testHeading() {
        XCTAssertEqual(WikiLink.parse("a#h"), WikiLink(target: "a", heading: "h"))
    }

    func testHeadingAndAlias() {
        XCTAssertEqual(WikiLink.parse("a#h|b"), WikiLink(target: "a", heading: "h", alias: "b"))
        // `#` after the `|` belongs to the alias.
        XCTAssertEqual(WikiLink.parse("a|b#c"), WikiLink(target: "a", alias: "b#c"))
    }

    func testFolderPath() {
        XCTAssertEqual(WikiLink.parse("f/a"), WikiLink(target: "f/a"))
    }

    func testEmbed() {
        XCTAssertEqual(WikiLink.parse("!img.png"), WikiLink(target: "img.png", isEmbed: true))
        XCTAssertEqual(WikiLink.parse("![[img.png|200]]"),
                       WikiLink(target: "img.png", alias: "200", isEmbed: true))
        XCTAssertEqual(WikiLink.parse("[[a]]"), WikiLink(target: "a"))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(WikiLink.parse("  My Note  #  Sec  |  shown  "),
                       WikiLink(target: "My Note", heading: "Sec", alias: "shown"))
        XCTAssertEqual(WikiLink.parse("a| "), WikiLink(target: "a"), "empty alias → nil")
        XCTAssertEqual(WikiLink.parse("a#"), WikiLink(target: "a"), "empty heading → nil")
    }

    func testMarkdownSuffixOnlyStrippedForMatching() {
        let link = WikiLink.parse("Note.MD")
        XCTAssertEqual(link?.target, "Note.MD")
        XCTAssertEqual(link?.matchTarget, "Note")
        XCTAssertEqual(WikiLink.parse("f/a.md")?.matchTarget, "f/a")
        XCTAssertEqual(WikiLink.parse(".md")?.matchTarget, ".md")
        XCTAssertEqual(WikiLink.parse("pic.png")?.matchTarget, "pic.png")
    }

    func testEscapedPipeInTables() {
        XCTAssertEqual(WikiLink.parse(#"a\|b"#), WikiLink(target: "a", alias: "b"))
    }

    func testSameDocumentHeadingAndInvalid() {
        XCTAssertEqual(WikiLink.parse("#Intro"), WikiLink(target: "", heading: "Intro"))
        XCTAssertEqual(WikiLink.parse("#Intro")?.lookupKeys, [])
        XCTAssertNil(WikiLink.parse(""))
        XCTAssertNil(WikiLink.parse("   "))
        XCTAssertNil(WikiLink.parse("|alias"))
        XCTAssertNil(WikiLink.parse("a\nb"))
    }

    func testLookupKeys() {
        XCTAssertEqual(WikiLink.parse("a")?.lookupKeys, ["a"])
        XCTAssertEqual(WikiLink.parse("a#h|b")?.lookupKeys, ["a", "a#h"])
    }
}

final class WikiLinkScanTests: XCTestCase {

    func testFindsLinksAndEmbeds() {
        let md = "See [[One]] and [[two|Two]], ![[pic.png]] and [[f/three#h]]."
        XCTAssertEqual(WikiLink.links(in: md), [
            WikiLink(target: "One"),
            WikiLink(target: "two", alias: "Two"),
            WikiLink(target: "pic.png", isEmbed: true),
            WikiLink(target: "f/three", heading: "h"),
        ])
        XCTAssertEqual(WikiLink.targets(in: md), ["One", "two", "pic.png", "f/three"])
    }

    func testSkipsFencedCode() {
        let md = """
        [[before]]
        ```swift
        let x = "[[inside]]"
        ```
        ~~~~
        [[tilde]]
        ```
        [[still inside: a shorter or different fence does not close]]
        ~~~~
          ```
        [[indented fence]]
          ```
        [[after]]
        """
        XCTAssertEqual(WikiLink.targets(in: md), ["before", "after"])
    }

    func testUnclosedFenceSwallowsRest() {
        XCTAssertEqual(WikiLink.targets(in: "[[a]]\n```\n[[b]]\n"), ["a"])
    }

    func testSkipsInlineCode() {
        let md = "`[[code]]` [[real]] ``a ` [[double]]`` `unclosed [[ok]]"
        XCTAssertEqual(WikiLink.targets(in: md), ["real", "ok"])
    }

    func testOddBrackets() {
        XCTAssertEqual(WikiLink.targets(in: "[[a [[b]] [[]] [[ c ]] [[unclosed"), ["b", "c"])
        XCTAssertEqual(WikiLink.targets(in: "[[#Local heading]] [[x]]"), ["x"])
        XCTAssertEqual(WikiLink.targets(in: "한국어 [[노트]] 🚀 [[é]]"), ["노트", "é"])
    }
}

final class WikiLinkIndexTests: XCTestCase {

    private let rootA = URL(fileURLWithPath: "/vault/A")
    private let rootB = URL(fileURLWithPath: "/vault/B")

    /// A tree from root-relative paths: Markdown → nodes, images → assets.
    private func tree(_ root: URL, _ paths: [String]) -> FolderTree {
        var assets: [URL] = []
        var top = FileNodeBuilder(url: root)
        for path in paths {
            let ext = (path as NSString).pathExtension.lowercased()
            if FolderScanOptions.defaultAssetExtensions.contains(ext) {
                assets.append(root.appendingPathComponent(path))
            } else {
                top.insert(path.split(separator: "/").map(String.init))
            }
        }
        return FolderTree(root: top.node(), assetFiles: assets)
    }

    private func sampleIndex() -> WikiLinkIndex {
        WikiLinkIndex(trees: [tree(rootA, [
            "Home.md",
            "notes/Note.md",
            "notes/deep/Note.md",
            "other/Note.md",
            "projects/Plan.md",
            "archive/projects/Plan.md",
            "guide.markdown",
            "v1.2 release.md",
            "assets/pic.png",
            "notes/pic.png",
            "Photo.JPG",
        ])])
    }

    private func resolve(_ index: WikiLinkIndex, _ raw: String, from doc: String,
                         root: URL? = nil) -> String? {
        let base = root ?? rootA
        guard let link = WikiLink.parse(raw),
              let r = index.resolve(link, from: base.appendingPathComponent(doc)) else { return nil }
        let rootName = r.rootURL.lastPathComponent
        return (root == nil && rootName == "A") ? r.relativePath : "\(rootName):\(r.relativePath)"
    }

    func testSameFolderPreferred() {
        let index = sampleIndex()
        XCTAssertEqual(resolve(index, "Note", from: "notes/deep/x.md"), "notes/deep/Note.md")
        XCTAssertEqual(resolve(index, "Note", from: "other/x.md"), "other/Note.md")
    }

    func testShortestPathThenAlphabetical() {
        let index = sampleIndex()
        // From the root: notes/Note.md and other/Note.md tie on depth; "notes" < "other".
        XCTAssertEqual(resolve(index, "Note", from: "Home.md"), "notes/Note.md")
        XCTAssertEqual(resolve(index, "Plan", from: "Home.md"), "projects/Plan.md")
    }

    func testFolderSuffixAndExactPath() {
        let index = sampleIndex()
        XCTAssertEqual(resolve(index, "deep/Note", from: "Home.md"), "notes/deep/Note.md")
        XCTAssertEqual(resolve(index, "projects/Plan", from: "archive/projects/x.md"),
                       "projects/Plan.md", "exact root-relative path beats same folder")
        XCTAssertEqual(resolve(index, "archive/projects/Plan", from: "Home.md"), "archive/projects/Plan.md")
        XCTAssertNil(resolve(index, "jects/Plan", from: "Home.md"), "suffix matches whole components")
        XCTAssertEqual(resolve(index, "/notes/Note", from: "other/x.md"), "notes/Note.md")
        XCTAssertNil(resolve(index, "/deep/Note", from: "Home.md"), "leading / anchors at the root")
    }

    func testRelativePathTargets() {
        let index = sampleIndex()
        XCTAssertEqual(resolve(index, "../other/Note", from: "notes/x.md"), "other/Note.md")
        XCTAssertEqual(resolve(index, "./deep/Note.md", from: "notes/x.md"), "notes/deep/Note.md")
        XCTAssertNil(resolve(index, "../../../etc/Note", from: "notes/x.md"))
    }

    func testCaseInsensitiveAndMarkdownImplied() {
        let index = sampleIndex()
        XCTAssertEqual(resolve(index, "home", from: "notes/x.md"), "Home.md")
        XCTAssertEqual(resolve(index, "HOME.MD", from: "notes/x.md"), "Home.md")
        XCTAssertEqual(resolve(index, "Guide", from: "Home.md"), "guide.markdown")
        XCTAssertEqual(resolve(index, "guide.markdown", from: "Home.md"), "guide.markdown")
        XCTAssertEqual(resolve(index, "v1.2 release", from: "Home.md"), "v1.2 release.md")
    }

    func testImageVersusNote() throws {
        let index = sampleIndex()
        XCTAssertEqual(resolve(index, "!pic.png", from: "Home.md"), "assets/pic.png")
        XCTAssertEqual(resolve(index, "pic.png", from: "notes/x.md"), "notes/pic.png")
        XCTAssertEqual(resolve(index, "photo.jpg", from: "Home.md"), "Photo.JPG")
        XCTAssertNil(resolve(index, "pic", from: "Home.md"), "images need their extension")
        let link = try XCTUnwrap(WikiLink.parse("!pic.png"))
        XCTAssertEqual(index.resolve(link, from: rootA.appendingPathComponent("Home.md"))?.kind, .image)
        let note = try XCTUnwrap(WikiLink.parse("Home"))
        let resolved = try XCTUnwrap(index.resolve(note, from: rootA.appendingPathComponent("x.md")))
        XCTAssertEqual(resolved.kind, .note)
        XCTAssertEqual(resolved.url, FileNode.canonicalURL(rootA.appendingPathComponent("Home.md")))
        XCTAssertEqual(resolved.rootURL, FileNode.canonicalURL(rootA))
    }

    func testUnresolved() {
        let index = sampleIndex()
        XCTAssertNil(resolve(index, "Missing", from: "Home.md"))
        XCTAssertNil(resolve(index, "missing.png", from: "Home.md"))
        XCTAssertNil(resolve(index, "doc.pdf", from: "Home.md"))
        XCTAssertNil(resolve(index, "#Heading", from: "Home.md"))
        XCTAssertNil(WikiLinkIndex(trees: []).resolve(WikiLink(target: "x"), from: rootA))
    }

    func testMultipleRoots() {
        let index = WikiLinkIndex(trees: [
            tree(rootA, ["Shared.md", "OnlyA.md"]),
            tree(rootB, ["Shared.md", "sub/OnlyB.md", "img/b.png"]),
        ])
        XCTAssertEqual(index.count, 5)
        XCTAssertEqual(resolve(index, "Shared", from: "x.md", root: rootA), "A:Shared.md")
        XCTAssertEqual(resolve(index, "Shared", from: "x.md", root: rootB), "B:Shared.md",
                       "the document's own root wins a tie")
        XCTAssertEqual(resolve(index, "OnlyB", from: "x.md", root: rootA), "B:sub/OnlyB.md")
        XCTAssertEqual(resolve(index, "b.png", from: "x.md", root: rootA), "B:img/b.png")
        XCTAssertEqual(resolve(index, "OnlyA", from: "deep/x.md", root: rootB), "A:OnlyA.md")
    }

    func testResolutionsMap() {
        let index = sampleIndex()
        let md = """
        [[Home]] [[Note#Sec|alias]] ![[pic.png]] [[Missing]] `[[Plan]]`
        [[Home#Top]]
        """
        let map = index.resolutions(in: md, from: rootA.appendingPathComponent("other/x.md"))
        XCTAssertEqual(Set(map.keys), ["Home", "Home#Top", "Note", "Note#Sec", "pic.png"])
        XCTAssertEqual(map["Note"]?.relativePath, "other/Note.md")
        XCTAssertEqual(map["Note#Sec"], map["Note"])
        XCTAssertEqual(map["pic.png"]?.kind, .image)
    }

    // MARK: - Performance

    func testBuildingIndexFor20kFilesIsFast() {
        // 20k notes + 2k images, 50 folders × 2 levels, generated in memory.
        var top = FileNodeBuilder(url: rootA)
        var assets: [URL] = []
        for i in 0..<20_000 {
            top.insert(["area\(i % 50)", "topic\(i % 7)", "note \(i).md"])
        }
        for i in 0..<2_000 {
            assets.append(rootA.appendingPathComponent("area\(i % 50)/assets/img\(i).png"))
        }
        let big = FolderTree(root: top.node(), assetFiles: assets)
        XCTAssertEqual(big.flatFiles.count, 20_000)

        var best = Double.infinity
        var index = WikiLinkIndex(trees: [])
        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            index = WikiLinkIndex(trees: [big])
            best = min(best, CFAbsoluteTimeGetCurrent() - start)
        }
        XCTAssertEqual(index.count, 22_000)
        print("WikiLinkIndex build, 22k files: \(Int(best * 1000)) ms")
        XCTAssertLessThan(best, 0.2, "index build took \(Int(best * 1000)) ms")

        let start = CFAbsoluteTimeGetCurrent()
        for i in stride(from: 0, to: 20_000, by: 20) {
            XCTAssertNotNil(index.resolve(WikiLink(target: "note \(i)"),
                                          from: rootA.appendingPathComponent("area0/x.md")))
        }
        let lookups = CFAbsoluteTimeGetCurrent() - start
        print("WikiLinkIndex 1000 lookups: \(Int(lookups * 1000)) ms")
    }
}

/// Builds a `FileNode` folder tree from path components (test helper).
struct FileNodeBuilder {
    let url: URL
    private var folders: [String: FileNodeBuilder] = [:]
    private var files: [String] = []

    init(url: URL) { self.url = url }

    mutating func insert(_ components: [String]) {
        guard let first = components.first else { return }
        if components.count == 1 {
            files.append(first)
        } else {
            let childURL = url.appendingPathComponent(first)
            folders[first, default: FileNodeBuilder(url: childURL)]
                .insert(Array(components.dropFirst()))
        }
    }

    func node() -> FileNode {
        let kids = folders.values.map { $0.node() }
            + files.map { FileNode(url: url.appendingPathComponent($0), kind: .file) }
        return FileNode(url: url, kind: .folder, children: kids)
    }
}
