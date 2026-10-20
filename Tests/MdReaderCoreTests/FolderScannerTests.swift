import XCTest
@testable import MdReaderCore

final class FolderScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        // Deliberately the `/var/...` spelling; the scanner must cope with
        // Foundation handing back `/private/var/...` children.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ relative: String, _ text: String = "# x\n") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    /// Relative paths of every node, folders suffixed with "/", in display order.
    private func outline(_ node: FileNode) -> [String] {
        var lines: [String] = []
        func visit(_ n: FileNode) {
            for child in n.children ?? [] {
                let rel = FilePathDisplay.relativePath(of: child.url, in: root)
                lines.append(child.isFolder ? rel + "/" : rel)
                visit(child)
            }
        }
        visit(node)
        return lines
    }

    func testNestedScan() throws {
        try touch("a.md")
        try touch("docs/guide.markdown")
        try touch("docs/deep/er/notes.MD")
        try touch("docs/deep/er/notes.txt")

        let result = FolderScanner.scan(root)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.root.url, FileNode.canonicalURL(root))
        XCTAssertEqual(result.root.kind, .folder)
        XCTAssertEqual(outline(result.root), [
            "docs/", "docs/deep/", "docs/deep/er/", "docs/deep/er/notes.MD",
            "docs/guide.markdown", "a.md",
        ])
        // URLs hang off the root as given (no `/private` leaking in).
        let docs = try XCTUnwrap(result.root.children?.first)
        XCTAssertEqual(docs.url, FileNode.canonicalURL(root.appendingPathComponent("docs")))
        XCTAssertEqual(docs.id, docs.url)
    }

    func testAllMarkdownExtensionsAreListed() throws {
        for ext in MarkdownDocumentIO.markdownExtensions { try touch("f.\(ext)") }
        try touch("f.txt")
        try touch("f.html")
        let names = FolderScanner.scan(root).root.children?.map(\.name) ?? []
        XCTAssertEqual(Set(names), Set(MarkdownDocumentIO.markdownExtensions.map { "f.\($0)" }))
    }

    func testHiddenIgnoredAndSymlinkedDirectoriesAreSkipped() throws {
        try touch("keep.md")
        try touch(".git/HEAD.md")
        try touch(".obsidian/workspace.md")
        try touch(".trash/old.md")
        try touch(".hidden.md")
        try touch("node_modules/pkg/README.md")
        try touch("outside/linked.md")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("outside"))
        // A package (e.g. a .textbundle) is a document, not a folder to browse.
        try touch("Doc.textbundle/text.md")

        let paths = outline(FolderScanner.scan(root).root)
        XCTAssertEqual(paths, ["outside/", "outside/linked.md", "keep.md"])
    }

    func testSymlinkedDirectoryFollowedWhenAskedWithoutLooping() throws {
        try touch("real/a.md")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("real/loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias"),
            withDestinationURL: root.appendingPathComponent("real"))
        var options = FolderScanOptions()
        options.followSymlinkedDirectories = true
        let result = FolderScanner.scan(root, options: options)
        let paths = outline(result.root)
        XCTAssertTrue(paths.contains("alias/a.md"), "\(paths)")
        XCTAssertTrue(paths.contains("real/a.md"), "\(paths)")
        XCTAssertFalse(paths.contains { $0.contains("loop/") }, "cycle must be cut: \(paths)")
    }

    func testSymlinkedMarkdownFileIsListed() throws {
        try touch("elsewhere/target.txt")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias.md"),
            withDestinationURL: root.appendingPathComponent("elsewhere/target.txt"))
        // Dangling links are dropped.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dangling.md"),
            withDestinationURL: root.appendingPathComponent("nope.md"))
        XCTAssertEqual(outline(FolderScanner.scan(root).root), ["alias.md"])
    }

    func testEmptyAndNonMarkdownFoldersArePruned() throws {
        try mkdir("empty")
        try touch("images/pic.png")
        try touch("nested/only/dirs/here.txt")
        try mkdir("nested/also/empty")
        try touch("nested/x/y.md")
        XCTAssertEqual(outline(FolderScanner.scan(root).root),
                       ["nested/", "nested/x/", "nested/x/y.md"])
    }

    func testEmptyRootStillReturnsRootNode() throws {
        let result = FolderScanner.scan(root)
        XCTAssertEqual(result.root.children, [])
        XCTAssertFalse(result.truncated)
    }

    func testFoldersFirstThenFinderOrder() throws {
        try touch("file10.md")
        try touch("file2.md")
        try touch("File1.md")
        try touch("b/x.md")
        try touch("A/x.md")
        try touch("z.md")
        let names = FolderScanner.scan(root).root.children?.map(\.name)
        XCTAssertEqual(names, ["A", "b", "File1.md", "file2.md", "file10.md", "z.md"])
    }

    func testFileCapTruncatesInDisplayOrder() throws {
        try touch("sub/1.md")
        try touch("sub/2.md")
        for i in 1...5 { try touch("top\(i).md") }
        var options = FolderScanOptions()
        options.maxFiles = 4
        let result = FolderScanner.scan(root, options: options)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(outline(result.root), ["sub/", "sub/1.md", "sub/2.md", "top1.md", "top2.md"])

        options.maxFiles = 7
        let exact = FolderScanner.scan(root, options: options)
        XCTAssertFalse(exact.truncated, "exactly at the cap is not truncated")
        XCTAssertEqual(FolderTree(root: exact.root).flatFiles.count, 7)
    }

    func testMaxDepth() throws {
        try touch("top.md")
        try touch("l1/a.md")
        try touch("l1/l2/b.md")
        var options = FolderScanOptions()
        options.maxDepth = 2
        XCTAssertEqual(outline(FolderScanner.scan(root, options: options).root),
                       ["l1/", "l1/a.md", "top.md"])
        options.maxDepth = 1
        XCTAssertEqual(outline(FolderScanner.scan(root, options: options).root), ["top.md"])
    }

    func testScanDoesNotReadFileContents() throws {
        // An unreadable file is still listed: the scanner only looks at names.
        try touch("secret.md")
        let url = root.appendingPathComponent("secret.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        XCTAssertEqual(outline(FolderScanner.scan(root).root), ["secret.md"])
    }

    // MARK: - assets

    private func assetPaths(_ urls: [URL]) -> [String] {
        urls.map { FilePathDisplay.relativePath(of: $0, in: root) }
    }

    func testImageAssetsCollectedButNotInTree() throws {
        try touch("note.md")
        try touch("pic.PNG")
        try touch("attachments/a.jpg")
        try touch("attachments/sub/b.svg")
        try touch("attachments/doc.pdf")
        try touch("notes/n.md")
        try touch("notes/c.webp")
        try touch(".obsidian/icon.png")
        try touch(".hidden.png")
        try touch("node_modules/pkg/logo.png")
        try touch("Bundle.textbundle/assets/d.png")

        let result = FolderScanner.scan(root)
        XCTAssertEqual(assetPaths(result.assetFiles), [
            "attachments/a.jpg", "attachments/sub/b.svg", "notes/c.webp", "pic.PNG",
        ])
        XCTAssertFalse(result.assetsTruncated)
        XCTAssertEqual(result.assetFiles.first,
                       FileNode.canonicalURL(root.appendingPathComponent("attachments/a.jpg")))
        // Image-only folders are still pruned from the sidebar tree.
        XCTAssertEqual(outline(result.root), ["notes/", "notes/n.md", "note.md"])
        let tree = FolderTree(scanning: root)
        XCTAssertEqual(tree.flatFiles.map(\.lastPathComponent), ["n.md", "note.md"])
        XCTAssertEqual(tree.assetFiles, result.assetFiles)
        XCTAssertFalse(tree.contains(root.appendingPathComponent("pic.PNG")))
        XCTAssertNil(tree.node(at: root.appendingPathComponent("attachments")))
    }

    func testAssetCapAndOptOut() throws {
        for i in 1...5 { try touch("img/\(i).png") }
        try touch("a.md")
        var options = FolderScanOptions()
        options.maxAssetFiles = 3
        let capped = FolderScanner.scan(root, options: options)
        XCTAssertEqual(capped.assetFiles.count, 3)
        XCTAssertTrue(capped.assetsTruncated)
        XCTAssertFalse(capped.truncated, "the Markdown cap is separate")

        options.assetExtensions = []
        let none = FolderScanner.scan(root, options: options)
        XCTAssertEqual(none.assetFiles, [])
        XCTAssertFalse(none.assetsTruncated)
    }

    func testAssetsHonorMaxDepth() throws {
        try touch("top.png")
        try touch("l1/a.png")
        try touch("l1/l2/b.png")
        var options = FolderScanOptions()
        options.maxDepth = 2
        XCTAssertEqual(assetPaths(FolderScanner.scan(root, options: options).assetFiles),
                       ["l1/a.png", "top.png"])
    }

    // MARK: - rescan

    func testRescanRebuildsSubtreeIncludingNewSubfolders() throws {
        try touch("docs/a.md")
        try touch("docs/new/deeper/b.md")
        try mkdir("docs/empty")
        let kids = FolderScanner.rescan(directory: root.appendingPathComponent("docs"), root: root)
        XCTAssertEqual(kids.map(\.name), ["new", "a.md"])
        XCTAssertEqual(kids.first?.children?.first?.children?.first?.url,
                       FileNode.canonicalURL(root.appendingPathComponent("docs/new/deeper/b.md")))
    }

    func testRescanOfExcludedOrMissingDirectoryIsEmpty() throws {
        try touch(".git/x.md")
        try touch("node_modules/x.md")
        try touch("ok/x.md")
        XCTAssertEqual(FolderScanner.rescan(directory: root.appendingPathComponent(".git"), root: root), [])
        XCTAssertEqual(FolderScanner.rescan(directory: root.appendingPathComponent("node_modules"), root: root), [])
        XCTAssertEqual(FolderScanner.rescan(directory: root.appendingPathComponent("gone"), root: root), [])
        XCTAssertEqual(FolderScanner.rescan(directory: URL(fileURLWithPath: "/usr"), root: root), [])
        XCTAssertEqual(FolderScanner.rescan(directory: root.appendingPathComponent("ok"), root: root).count, 1)
    }

    func testRescanAcceptsPrivateVarSpelling() throws {
        try touch("docs/a.md")
        let real = URL(fileURLWithPath: FileNode.realPath(root)!)
        let kids = FolderScanner.rescan(directory: real.appendingPathComponent("docs"), root: root)
        XCTAssertEqual(kids.map(\.url), [FileNode.canonicalURL(root.appendingPathComponent("docs/a.md"))])
    }

    func testRescanHonorsBudgetAndDepth() throws {
        for i in 1...3 { try touch("docs/\(i).md") }
        try touch("docs/l2/deep.md")
        XCTAssertEqual(FolderScanner.rescan(
            directory: root.appendingPathComponent("docs"), root: root, budget: 2).count, 2)
        var options = FolderScanOptions()
        options.maxDepth = 2
        XCTAssertEqual(FolderScanner.rescan(
            directory: root.appendingPathComponent("docs"), root: root, options: options).map(\.name),
            ["1.md", "2.md", "3.md"])
        XCTAssertEqual(FolderScanner.rescan(
            directory: root.appendingPathComponent("docs/l2"), root: root, options: options), [])
    }
}
