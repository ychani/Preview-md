import XCTest
@testable import MdReaderCore

final class FolderTreeTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp-free/Root", isDirectory: true)

    private func file(_ relative: String) -> FileNode {
        FileNode(url: root.appendingPathComponent(relative), kind: .file)
    }

    private func folder(_ relative: String, _ children: [FileNode]) -> FileNode {
        FileNode(url: root.appendingPathComponent(relative), kind: .folder, children: children)
    }

    private func url(_ relative: String) -> URL {
        FileNode.canonicalURL(root.appendingPathComponent(relative))
    }

    /// root/
    ///   a/ (x.md, y.md)
    ///   b/ c/ (z.md)
    ///   top.md
    private func sampleTree() -> FolderTree {
        FolderTree(root: FileNode(url: root, kind: .folder, children: [
            file("top.md"),
            folder("b", [folder("b/c", [file("b/c/z.md")])]),
            folder("a", [file("a/y.md"), file("a/x.md")]),
        ]))
    }

    func testFlatFilesInDisplayOrder() {
        XCTAssertEqual(sampleTree().flatFiles, [
            url("a/x.md"), url("a/y.md"), url("b/c/z.md"), url("top.md"),
        ])
    }

    func testRootURLIsCanonical() {
        XCTAssertEqual(sampleTree().rootURL.path, "/tmp-free/Root")
        XCTAssertFalse(sampleTree().rootURL.hasDirectoryPath)
    }

    func testContains() {
        let tree = sampleTree()
        XCTAssertTrue(tree.contains(root))
        XCTAssertTrue(tree.contains(url("b/c")))
        XCTAssertTrue(tree.contains(root.appendingPathComponent("b/c/", isDirectory: true)))
        XCTAssertTrue(tree.contains(url("b/c/z.md")))
        XCTAssertFalse(tree.contains(url("b/c/nope.md")))
        XCTAssertFalse(tree.contains(URL(fileURLWithPath: "/elsewhere/top.md")))
    }

    func testAncestors() {
        let tree = sampleTree()
        XCTAssertEqual(tree.ancestors(of: url("b/c/z.md")), [url("b"), url("b/c")])
        XCTAssertEqual(tree.ancestors(of: url("top.md")), [])
        XCTAssertEqual(tree.ancestors(of: root), [])
        XCTAssertEqual(tree.ancestors(of: URL(fileURLWithPath: "/elsewhere/x.md")), [])
    }

    func testNodeLookup() {
        let tree = sampleTree()
        XCTAssertEqual(tree.node(at: url("b/c"))?.children?.map(\.name), ["z.md"])
        XCTAssertNil(tree.node(at: url("missing")))
    }

    func testReplaceChildrenPreservesSiblings() {
        var tree = sampleTree()
        let before = tree.root.children!
        tree.replaceChildren(of: url("a"), with: [file("a/new.md"), file("a/x.md")])
        let after = tree.root.children!
        XCTAssertEqual(after.map(\.name), ["a", "b", "top.md"])
        XCTAssertEqual(after[1], before[1], "sibling subtree untouched")
        XCTAssertEqual(after[2], before[2])
        XCTAssertEqual(tree.flatFiles, [url("a/new.md"), url("a/x.md"), url("b/c/z.md"), url("top.md")])
        XCTAssertFalse(tree.contains(url("a/y.md")))
    }

    func testReplaceChildrenInsertsNewNestedFolderPath() {
        var tree = sampleTree()
        tree.replaceChildren(of: url("new/deeper"), with: [file("new/deeper/n.md")])
        XCTAssertEqual(tree.root.children?.map(\.name), ["a", "b", "new", "top.md"])
        XCTAssertTrue(tree.contains(url("new")))
        XCTAssertTrue(tree.contains(url("new/deeper/n.md")))
        XCTAssertEqual(tree.ancestors(of: url("new/deeper/n.md")), [url("new"), url("new/deeper")])
        XCTAssertEqual(tree.flatFiles.last, url("top.md"))
    }

    func testReplaceChildrenRemovesEmptiedFolderAndEmptiedParents() {
        var tree = sampleTree()
        tree.replaceChildren(of: url("b/c"), with: [])
        XCTAssertEqual(tree.root.children?.map(\.name), ["a", "top.md"],
                       "b held only c, so it goes too")
        XCTAssertFalse(tree.contains(url("b")))
    }

    func testReplaceChildrenWithNewSubfolderSubtree() {
        var tree = sampleTree()
        // What a rescan of `b` returns after `b/d/` (with a file) appears.
        tree.replaceChildren(of: url("b"), with: [
            folder("b/d", [file("b/d/w.md")]),
            folder("b/c", [file("b/c/z.md")]),
        ])
        XCTAssertEqual(tree.node(at: url("b"))?.children?.map(\.name), ["c", "d"])
        XCTAssertTrue(tree.contains(url("b/d/w.md")))
    }

    func testReplaceChildrenOfRootAndEmptyingRoot() {
        var tree = sampleTree()
        tree.replaceChildren(of: root, with: [file("only.md")])
        XCTAssertEqual(tree.flatFiles, [url("only.md")])
        tree.replaceChildren(of: root, with: [])
        XCTAssertEqual(tree.root.children, [])
        XCTAssertEqual(tree.root.url, FileNode.canonicalURL(root), "root always stays")
        XCTAssertEqual(tree.flatFiles, [])
    }

    func testReplaceChildrenOfUnknownEmptyFolderIsNoOp() {
        var tree = sampleTree()
        let before = tree
        tree.replaceChildren(of: url("ghost/dir"), with: [])
        tree.replaceChildren(of: URL(fileURLWithPath: "/elsewhere"), with: [file("top.md")])
        XCTAssertEqual(tree, before)
    }

    func testFileReplacedByFolderOfSameName() {
        var tree = FolderTree(root: FileNode(url: root, kind: .folder, children: [file("x.md")]))
        tree.replaceChildren(of: url("x.md"), with: [file("x.md/inner.md")])
        XCTAssertEqual(tree.root.children?.count, 1)
        XCTAssertEqual(tree.root.children?.first?.kind, .folder)
        XCTAssertEqual(tree.flatFiles, [url("x.md/inner.md")])
    }

    // MARK: - refresh (disk)

    func testRefreshFromDiskKeepsCap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderTreeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func touch(_ rel: String) throws {
            let u = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("# x\n".utf8).write(to: u)
        }
        try touch("a/1.md")
        try touch("b/1.md")
        var options = FolderScanOptions()
        options.maxFiles = 3
        var tree = FolderTree(scanning: dir, options: options)
        XCTAssertEqual(tree.flatFiles.count, 2)
        XCTAssertFalse(tree.isTruncated)

        try touch("b/2.md")
        try touch("b/3.md")
        XCTAssertTrue(tree.refresh(directory: dir.appendingPathComponent("b"), options: options))
        XCTAssertEqual(tree.flatFiles.count, 3, "only one slot left for b")
        XCTAssertTrue(tree.isTruncated)
        XCTAssertTrue(tree.contains(dir.appendingPathComponent("a/1.md")))

        XCTAssertFalse(tree.refresh(directory: dir.appendingPathComponent("b"), options: options),
                       "nothing changed")

        try FileManager.default.removeItem(at: dir.appendingPathComponent("a"))
        XCTAssertTrue(tree.refresh(directory: dir, options: options))
        XCTAssertFalse(tree.contains(dir.appendingPathComponent("a")))
    }
}
