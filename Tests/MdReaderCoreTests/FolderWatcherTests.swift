import XCTest
@testable import MdReaderCore

final class FolderWatcherTests: XCTestCase {

    private var root: URL!
    private var watcher: FolderWatcher?
    private var events: [FolderWatcher.Event] = []
    private var onEvent: ((FolderWatcher.Event) -> Void)?

    override func setUpWithError() throws {
        // `/var/...` spelling on purpose: FSEvents reports `/private/var/...`
        // and the watcher must map back to this form.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try touch("seed.md")
        events = []
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        onEvent = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ relative: String) -> URL {
        FileNode.canonicalURL(root.appendingPathComponent(relative))
    }

    private func touch(_ relative: String) throws {
        let u = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("# x\n".utf8).write(to: u)
    }

    private func startWatcher() {
        let watcher = FolderWatcher(root: root, queue: .main, latency: 0.1) { [weak self] event in
            self?.events.append(event)
            self?.onEvent?(event)
        }
        XCTAssertTrue(watcher.start())
        self.watcher = watcher
        // Let events from setUp's writes flush before the test acts.
        drain(0.3)
        events = []
    }

    private func drain(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Changed directories reported so far.
    private var changedDirectories: [URL] {
        events.flatMap { event -> [URL] in
            if case .changed(let dirs) = event { return dirs }
            return []
        }
    }

    /// Waits until some `.changed` event names a directory satisfying `match`.
    private func expectChange(timeout: TimeInterval = 5, _ description: String,
                              where match: @escaping (URL) -> Bool,
                              after action: () throws -> Void) rethrows {
        let exp = expectation(description: description)
        exp.assertForOverFulfill = false
        onEvent = { event in
            if case .changed(let dirs) = event, dirs.contains(where: match) { exp.fulfill() }
        }
        try action()
        wait(for: [exp], timeout: timeout)
        onEvent = nil
    }

    func testCreateIsReportedAsRootChange() throws {
        startWatcher()
        let rootURL = FileNode.canonicalURL(root)
        try expectChange("root changed", where: { $0 == rootURL }) { try touch("new.md") }
        XCTAssertFalse(changedDirectories.contains { $0.path.hasPrefix("/private/") },
                       "URLs must use the root's spelling: \(changedDirectories)")
    }

    func testDeleteIsReported() throws {
        try touch("sub/gone.md")
        startWatcher()
        try expectChange("sub changed", where: { $0 == self.url("sub") }) {
            try FileManager.default.removeItem(at: root.appendingPathComponent("sub/gone.md"))
        }
    }

    func testRenameIsReported() throws {
        try touch("sub/old.md")
        startWatcher()
        try expectChange("sub changed", where: { $0 == self.url("sub") }) {
            try FileManager.default.moveItem(at: root.appendingPathComponent("sub/old.md"),
                                             to: root.appendingPathComponent("sub/new.md"))
        }
    }

    func testNestedFolderCreateIsCoveredAndRefreshPicksItUp() throws {
        var tree = FolderTree(scanning: root)
        XCTAssertEqual(tree.flatFiles, [url("seed.md")])
        startWatcher()
        let target = url("n1/n2/deep.md")
        // Any reported directory at or above n1/n2 covers the new file.
        try expectChange("ancestor of n1/n2 changed",
                         where: { target.path.hasPrefix($0.path + "/") }) {
            try touch("n1/n2/deep.md")
        }
        drain(0.3) // collect the rest of the batch
        for dir in changedDirectories { tree.refresh(directory: dir) }
        XCTAssertTrue(tree.contains(target), "\(changedDirectories) → \(tree.flatFiles)")
        XCTAssertEqual(tree.ancestors(of: target), [url("n1"), url("n1/n2")])
    }

    func testRootRemovalIsReportedAsRootGone() throws {
        startWatcher()
        let exp = expectation(description: "rootGone")
        exp.assertForOverFulfill = false
        onEvent = { if $0 == .rootGone { exp.fulfill() } }
        let moved = root.deletingLastPathComponent()
            .appendingPathComponent("FolderWatcherTests-moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        wait(for: [exp], timeout: 5)
    }

    func testNoEventsAfterStop() throws {
        startWatcher()
        watcher?.stop()
        XCTAssertFalse(watcher?.isRunning ?? true)
        try touch("after-stop.md")
        try touch("dir/after-stop.md")
        drain(1.0)
        XCTAssertEqual(events, [])
    }

    func testDeinitStopsWatching() throws {
        startWatcher()
        watcher = nil // deinit must stop the stream
        try touch("after-deinit.md")
        drain(1.0)
        XCTAssertEqual(events, [])
    }

    func testStartFailsForMissingRoot() {
        let missing = FolderWatcher(root: root.appendingPathComponent("nope")) { _ in }
        XCTAssertFalse(missing.start())
        XCTAssertFalse(missing.isRunning)
    }

    func testDroppingCoveredDescendants() {
        let a = URL(fileURLWithPath: "/r/a"), ab = URL(fileURLWithPath: "/r/a/b")
        let ab2 = URL(fileURLWithPath: "/r/ab"), r = URL(fileURLWithPath: "/r")
        XCTAssertEqual(FolderWatcher.droppingCoveredDescendants([ab, a, ab2]), [a, ab2])
        XCTAssertEqual(FolderWatcher.droppingCoveredDescendants([ab, r, a]), [r])
    }

    func testNoDescriptorLeak() throws {
        func openDescriptorCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }
        // Warm up FSEvents' own one-time connection before counting.
        startWatcher()
        watcher?.stop()
        watcher = nil
        drain(0.1)
        let before = openDescriptorCount()
        let rootURL = FileNode.canonicalURL(root)
        for i in 0..<5 {
            startWatcher()
            try expectChange("root changed", where: { $0 == rootURL }) { try touch("f\(i).md") }
            watcher?.stop()
            watcher = nil
        }
        drain(0.2)
        XCTAssertEqual(openDescriptorCount(), before)
    }
}
