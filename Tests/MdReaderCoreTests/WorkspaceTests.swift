import XCTest
@testable import MdReaderCore

final class WorkspaceTests: XCTestCase {

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - WorkspaceRoots.add

    func testAddAppendsInOrderCanonically() {
        var roots = WorkspaceRoots()
        XCTAssertEqual(roots.add(url("/ws/b/")), .added)
        XCTAssertEqual(roots.add(url("/ws/a")), .added)
        XCTAssertEqual(roots.roots.map(\.path), ["/ws/b", "/ws/a"])
        XCTAssertFalse(roots.roots[0].hasDirectoryPath)
    }

    func testAddAlreadyPresent() {
        var roots = WorkspaceRoots([url("/ws/a")])
        XCTAssertEqual(roots.add(url("/ws/a/")), .alreadyPresent)
        XCTAssertEqual(roots.add(url("/ws/x/../a")), .alreadyPresent)
        XCTAssertEqual(roots.roots.count, 1)
    }

    func testAddInsideExistingIsRejected() {
        var roots = WorkspaceRoots([url("/ws/a")])
        XCTAssertEqual(roots.add(url("/ws/a/notes/2026")), .insideExisting(FileNode.canonicalURL(url("/ws/a"))))
        XCTAssertEqual(roots.roots.count, 1)
    }

    func testAddContainingExistingIsRejected() {
        var roots = WorkspaceRoots([url("/ws/a/x"), url("/other"), url("/ws/b")])
        XCTAssertEqual(roots.add(url("/ws")), .containsExisting([
            FileNode.canonicalURL(url("/ws/a/x")), FileNode.canonicalURL(url("/ws/b")),
        ]))
        XCTAssertEqual(roots.roots.count, 3)
    }

    func testSiblingWithSharedPrefixIsNotNested() {
        var roots = WorkspaceRoots([url("/ws/notes")])
        XCTAssertEqual(roots.add(url("/ws/notes-old")), .added)
    }

    func testAddToleratesPrivateVarSplit() {
        var roots = WorkspaceRoots([url("/private/var/folders/x/vault")])
        XCTAssertEqual(roots.add(url("/var/folders/x/vault")), .alreadyPresent)
        XCTAssertEqual(roots.add(url("/var/folders/x/vault/sub")),
                       .insideExisting(FileNode.canonicalURL(url("/private/var/folders/x/vault"))))
    }

    func testInitDropsRejectedFolders() {
        let roots = WorkspaceRoots([url("/ws/a"), url("/ws/a/sub"), url("/ws/a"), url("/ws/b")])
        XCTAssertEqual(roots.roots.map(\.path), ["/ws/a", "/ws/b"])
    }

    // MARK: - remove / root(containing:)

    func testRemove() {
        var roots = WorkspaceRoots([url("/ws/a"), url("/ws/b")])
        XCTAssertFalse(roots.remove(url("/ws/a/sub")), "only a root itself can be removed")
        XCTAssertTrue(roots.remove(url("/ws/a/")))
        XCTAssertEqual(roots.roots.map(\.path), ["/ws/b"])
        XCTAssertFalse(roots.remove(url("/ws/a")))
        // Once removed, a nested folder can be added.
        XCTAssertEqual(roots.add(url("/ws/a/sub")), .added)
    }

    func testRootContaining() {
        let roots = WorkspaceRoots([url("/ws/a"), url("/ws/b")])
        XCTAssertEqual(roots.root(containing: URL(fileURLWithPath: "/ws/b/x/y.md"))?.path, "/ws/b")
        XCTAssertEqual(roots.root(containing: url("/ws/a"))?.path, "/ws/a")
        XCTAssertNil(roots.root(containing: URL(fileURLWithPath: "/ws/c.md")))
        XCTAssertNil(roots.root(containing: URL(fileURLWithPath: "/ws/ab/c.md")))
    }

    func testRootContainingPrivateVar() {
        let roots = WorkspaceRoots([url("/var/folders/x/vault")])
        XCTAssertEqual(roots.root(containing: URL(fileURLWithPath: "/private/var/folders/x/vault/n.md"))?.path,
                       "/var/folders/x/vault")
        let privateRoots = WorkspaceRoots([url("/private/var/folders/x/vault")])
        XCTAssertNotNil(privateRoots.root(containing: URL(fileURLWithPath: "/var/folders/x/vault/n.md")))
    }

    func testIndexOf() {
        let roots = WorkspaceRoots([url("/ws/a"), url("/ws/b")])
        XCTAssertEqual(roots.index(of: url("/ws/b/")), 1)
        XCTAssertNil(roots.index(of: url("/ws/b/sub")))
    }

    func testOutermost() {
        let kept = WorkspaceRoots.outermost([
            url("/ws/a/sub"), url("/ws/b"), url("/ws/a"), url("/ws/b/"), url("/ws/c"),
        ])
        XCTAssertEqual(kept.map(\.path), ["/ws/b", "/ws/a", "/ws/c"])
    }

    // MARK: - Bookmarks

    func testBookmarksRoundTripDroppingDeletedFolder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        let a = base.appendingPathComponent("a", isDirectory: true)
        let b = base.appendingPathComponent("b", isDirectory: true)
        let c = base.appendingPathComponent("c", isDirectory: true)
        for dir in [a, b, c] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let data = WorkspaceBookmarks.encode([a, b, c])
        XCTAssertEqual(data.count, 3)

        try FileManager.default.removeItem(at: b)
        let resolved = WorkspaceBookmarks.resolve(data)
        XCTAssertEqual(resolved.count, 2)
        // Bookmarks may resolve to the /private twin; compare by containment.
        let roots = WorkspaceRoots(resolved)
        XCTAssertEqual(roots.roots.count, 2)
        XCTAssertNotNil(roots.index(of: a))
        XCTAssertNotNil(roots.index(of: c))
        XCTAssertNil(roots.index(of: b))
        XCTAssertEqual(roots.index(of: a), 0, "order is kept")
    }

    func testResolveDropsGarbageAndFiles() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("note.md")
        try Data("x".utf8).write(to: file)

        let data = WorkspaceBookmarks.encode([file]) + [Data("not a bookmark".utf8)]
        XCTAssertEqual(WorkspaceBookmarks.resolve(data), [])
    }
}
