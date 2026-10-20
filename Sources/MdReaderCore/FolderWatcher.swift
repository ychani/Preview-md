import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and reports which directories changed,
/// so the explorer can rescan just those (`FolderTree.refresh(directory:)`).
///
/// Directory-level events only (no per-file flag): a create, delete or rename
/// is reported as a change to the directory that contains it. Directory URLs
/// are mapped back onto the root URL the watcher was given (FSEvents reports
/// real paths such as `/private/var/...`), so they match `FolderTree` URLs.
/// Within a batch, duplicates and directories already covered by a changed
/// ancestor are dropped.
///
/// Events are delivered on `queue`. Not thread-safe: call `start()`/`stop()`
/// on `queue` too. No callbacks arrive after `stop()` (or deinit).
public final class FolderWatcher {

    public enum Event: Equatable, Sendable {
        /// The contents of these directories changed; rescan each subtree.
        case changed(directories: [URL])
        /// FSEvents lost track (events dropped, or it asked for a full
        /// scan): rescan the whole tree.
        case mustRescanAll
        /// The root folder was deleted, renamed or moved away.
        case rootGone
    }

    public let root: URL
    private let queue: DispatchQueue
    private let latency: TimeInterval
    private let handler: (Event) -> Void

    private var stream: FSEventStreamRef?
    /// Shared with the stream's context. Cleared on stop, so a callback that
    /// was already queued when the stream was torn down is ignored.
    private var relay: Relay?
    /// `realpath` of the root at start — the prefix FSEvents paths carry.
    private var realRootPath = ""

    public init(
        root: URL,
        queue: DispatchQueue = .main,
        latency: TimeInterval = 0.5,
        handler: @escaping (Event) -> Void
    ) {
        self.root = FileNode.canonicalURL(root)
        self.queue = queue
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    public var isRunning: Bool { stream != nil }

    /// Starts watching. Returns false if the stream could not be started
    /// (e.g. the root does not exist).
    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        guard let realRoot = FileNode.realPath(root) else { return false }
        realRootPath = realRoot

        let relay = Relay(owner: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(relay).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Relay>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Relay>.fromOpaque(info).release()
            },
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let relay = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue()
            guard let owner = relay.owner else { return }
            let pathArray = unsafeBitCast(paths, to: NSArray.self)
            var batch: [(String, FSEventStreamEventFlags)] = []
            batch.reserveCapacity(count)
            for i in 0..<count {
                guard let path = pathArray[i] as? String else { continue }
                batch.append((path, flags[i]))
            }
            owner.handle(batch)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [realRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return false }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        self.stream = created
        self.relay = relay
        return true
    }

    public func stop() {
        relay?.owner = nil
        relay = nil
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    // MARK: - Event mapping

    private func handle(_ batch: [(path: String, flags: FSEventStreamEventFlags)]) {
        guard stream != nil else { return }
        let rescanAllFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount)
        let rootChangedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)

        var mustRescanAll = false
        var directories: [URL] = []
        var seen: Set<String> = []
        for (path, flags) in batch {
            if flags & rootChangedFlag != 0 {
                // RootChanged also fires when an ancestor is renamed and back;
                // only report the root gone if it really is.
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    mustRescanAll = true
                    continue
                }
                handler(.rootGone)
                return
            }
            if flags & rescanAllFlags != 0 { mustRescanAll = true }
            guard let url = mapToRoot(path), seen.insert(url.path).inserted else { continue }
            directories.append(url)
        }

        if mustRescanAll {
            handler(.mustRescanAll)
            return
        }
        let covered = Self.droppingCoveredDescendants(directories)
        guard !covered.isEmpty else { return }
        handler(.changed(directories: covered))
    }

    /// Maps a real path from FSEvents to the matching URL under `root`.
    private func mapToRoot(_ eventPath: String) -> URL? {
        var path = eventPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let relative: Substring
        if path == realRootPath {
            relative = ""
        } else if path.hasPrefix(realRootPath + "/") {
            relative = path.dropFirst(realRootPath.count + 1)
        } else if let components = FileNode.relativeComponents(
            of: URL(fileURLWithPath: path, isDirectory: false), under: root) {
            relative = Substring(components.joined(separator: "/"))
        } else {
            return nil
        }
        return relative.split(separator: "/").reduce(root) { $0.appendingNodeComponent(String($1)) }
    }

    /// Keeps first-seen order; drops any directory inside another listed one
    /// (rescanning the ancestor covers it).
    static func droppingCoveredDescendants(_ urls: [URL]) -> [URL] {
        let paths = urls.map(\.path)
        return urls.enumerated().filter { index, url in
            let path = url.path
            return !paths.enumerated().contains { other, otherPath in
                other != index && otherPath != path
                    && path.hasPrefix(otherPath == "/" ? "/" : otherPath + "/")
            }
        }.map(\.element)
    }

    /// Box the stream retains; holds the watcher weakly.
    private final class Relay {
        weak var owner: FolderWatcher?
        init(owner: FolderWatcher) { self.owner = owner }
    }
}
