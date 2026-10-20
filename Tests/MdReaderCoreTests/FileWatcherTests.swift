import XCTest
@testable import MdReaderCore

final class FileWatcherTests: XCTestCase {

    private var tempDir: URL!
    private var fileURL: URL!
    private var watcher: FileWatcher?
    private var events: [FileWatcher.Event] = []
    private var onEvent: ((FileWatcher.Event) -> Void)?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("doc.md")
        try Data("# one\n".utf8).write(to: fileURL)
        events = []
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Starts a watcher on the main queue with short timings so tests are fast.
    private func startWatcher(reappearTimeout: TimeInterval = 0.5) {
        let watcher = FileWatcher(
            url: fileURL, queue: .main, debounce: 0.05,
            reappearTimeout: reappearTimeout, pollInterval: 0.02
        ) { [weak self] event in
            self?.events.append(event)
            self?.onEvent?(event)
        }
        watcher.start()
        self.watcher = watcher
    }

    private func expectEvent(_ expected: FileWatcher.Event, timeout: TimeInterval = 3,
                             after action: () throws -> Void) rethrows {
        let exp = expectation(description: "event \(expected)")
        exp.assertForOverFulfill = false
        onEvent = { event in if event == expected { exp.fulfill() } }
        try action()
        wait(for: [exp], timeout: timeout)
        onEvent = nil
    }

    /// Spins the main run loop so pending (debounced) events can fire.
    private func drain(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func appendInPlace(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// What vim / VS Code / `MarkdownDocumentIO.write` do: write a sibling
    /// temp file, then rename it over the original.
    private func atomicReplace(with text: String) throws {
        let temp = tempDir.appendingPathComponent(".doc.md.tmp-\(UUID().uuidString)")
        try Data(text.utf8).write(to: temp)
        XCTAssertEqual(rename(temp.path, fileURL.path), 0)
    }

    func testInPlaceModificationIsReported() throws {
        startWatcher()
        try expectEvent(.modified) { try appendInPlace("two\n") }
        XCTAssertEqual(events, [.modified])
    }

    func testBurstOfWritesIsDebounced() throws {
        startWatcher()
        try expectEvent(.modified) {
            for i in 0..<5 { try appendInPlace("line \(i)\n") }
        }
        drain(0.2)
        XCTAssertEqual(events, [.modified])
    }

    func testAtomicReplaceIsReportedAndWatchingContinuesOnNewFile() throws {
        startWatcher()
        try expectEvent(.modified) { try atomicReplace(with: "# replaced\n") }
        XCTAssertTrue(watcher?.isWatchingFile ?? false, "should re-arm on the replacement inode")

        // A second change to the *new* file is still seen.
        events = []
        try expectEvent(.modified) { try appendInPlace("more\n") }
        XCTAssertFalse(events.contains(.deleted))
    }

    func testMarkdownDocumentIOSaveIsSeenAsModification() throws {
        startWatcher()
        try expectEvent(.modified) {
            try MarkdownDocumentIO.write("# saved\n", to: fileURL, format: .utf8)
        }
        XCTAssertFalse(events.contains(.deleted))
    }

    func testSlowReplaceWithinTimeoutIsNotADeletion() throws {
        startWatcher(reappearTimeout: 1.0)
        try expectEvent(.modified) {
            try FileManager.default.removeItem(at: fileURL)
            // Recreate after the debounce interval but inside the window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                try? Data("# back\n".utf8).write(to: self.fileURL)
            }
        }
        XCTAssertFalse(events.contains(.deleted))
    }

    func testDeleteThenRecreateLater() throws {
        startWatcher(reappearTimeout: 0.2)
        try expectEvent(.deleted) { try FileManager.default.removeItem(at: fileURL) }
        XCTAssertFalse(watcher?.isWatchingFile ?? true)

        try expectEvent(.modified) { try Data("# recreated\n".utf8).write(to: fileURL) }
        XCTAssertTrue(watcher?.isWatchingFile ?? false)

        events = []
        try expectEvent(.modified) { try appendInPlace("again\n") }
    }

    func testNoEventsAfterStop() throws {
        startWatcher()
        watcher?.stop()
        try appendInPlace("ignored\n")
        try atomicReplace(with: "ignored\n")
        drain(0.3)
        XCTAssertEqual(events, [])
    }

    func testDescriptorsAreClosed() throws {
        func openDescriptorCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }
        drain(0.05)
        let before = openDescriptorCount()
        for _ in 0..<10 {
            startWatcher()
            try expectEvent(.modified) { try atomicReplace(with: "x\n") }
            watcher?.stop()
            watcher = nil
        }
        drain(0.1) // let cancel handlers run
        XCTAssertEqual(openDescriptorCount(), before)
    }
}
