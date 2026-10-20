import Foundation

/// Watches one file *path* for changes made by other processes, surviving the
/// ways editors save:
///
/// - in-place writes (`.write` / `.extend`) are reported as `.modified`;
/// - atomic saves (write a temp file, rename it over the original — vim,
///   VS Code, our own `MarkdownDocumentIO.write`) and delete-then-recreate
///   unlink the watched inode. The watcher then re-opens the path, polling
///   for up to `reappearTimeout` so a slow replace isn't mistaken for a
///   deletion, and reports `.modified` once the new file is in place;
/// - if nothing reappears in time it reports `.deleted` and watches the parent
///   directory, reporting `.modified` if the file is recreated later.
///
/// Events are debounced (editors emit several per save) and delivered on
/// `queue`. Not thread-safe: call `start()`/`stop()` on `queue` too.
public final class FileWatcher {

    public enum Event: Equatable, Sendable {
        /// The file's contents may have changed (written, or replaced).
        case modified
        /// The file is gone and did not reappear within `reappearTimeout`.
        case deleted
    }

    public let url: URL
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let reappearTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let handler: (Event) -> Void

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var pollWork: DispatchWorkItem?
    private var isRunning = false

    public init(
        url: URL,
        queue: DispatchQueue = .main,
        debounce: TimeInterval = 0.2,
        reappearTimeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.05,
        handler: @escaping (Event) -> Void
    ) {
        self.url = url
        self.queue = queue
        self.debounce = debounce
        self.reappearTimeout = reappearTimeout
        self.pollInterval = pollInterval
        self.handler = handler
    }

    deinit {
        // Cancelling closes the descriptors (see the cancel handlers).
        fileSource?.cancel()
        directorySource?.cancel()
        debounceWork?.cancel()
        pollWork?.cancel()
    }

    /// True while a descriptor on the file itself is open (as opposed to
    /// waiting for it to reappear). Exposed for tests.
    public var isWatchingFile: Bool { fileSource != nil }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        if !armFile() {
            waitForReappearance(deadline: Date().addingTimeInterval(reappearTimeout))
        }
    }

    public func stop() {
        isRunning = false
        disarmFile()
        disarmDirectory()
        debounceWork?.cancel()
        debounceWork = nil
        pollWork?.cancel()
        pollWork = nil
    }

    // MARK: - File descriptor on the file

    @discardableResult
    private func armFile() -> Bool {
        disarmFile()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, !source.isCancelled else { return }
            self.handleFileEvent(source.data)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
        return true
    }

    private func disarmFile() {
        fileSource?.cancel()
        fileSource = nil
    }

    private func handleFileEvent(_ mask: DispatchSource.FileSystemEvent) {
        guard isRunning else { return }
        if mask.contains(.delete) || mask.contains(.rename) || mask.contains(.revoke) {
            // The inode we hold is no longer at the path. Drop it and look
            // for its replacement.
            disarmFile()
            waitForReappearance(deadline: Date().addingTimeInterval(reappearTimeout))
        } else {
            scheduleModified()
        }
    }

    // MARK: - Re-arming after delete / rename

    private func waitForReappearance(deadline: Date) {
        pollWork?.cancel()
        pollWork = nil
        guard isRunning else { return }
        if armFile() {
            scheduleModified()
            return
        }
        guard Date() < deadline else {
            debounceWork?.cancel()
            debounceWork = nil
            handler(.deleted)
            armDirectory()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.waitForReappearance(deadline: deadline)
        }
        pollWork = work
        queue.asyncAfter(deadline: .now() + pollInterval, execute: work)
    }

    private func armDirectory() {
        disarmDirectory()
        guard isRunning else { return }
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, !source.isCancelled, self.isRunning else { return }
            if self.armFile() {
                self.disarmDirectory()
                self.scheduleModified()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    private func disarmDirectory() {
        directorySource?.cancel()
        directorySource = nil
    }

    // MARK: - Debounce

    private func scheduleModified() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.debounceWork = nil
            self.handler(.modified)
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
