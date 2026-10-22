// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

extension UnivocalLocator {
    /// Yields each time a live server appears in `configuration.connectDirectory`
    /// (SPEC §16.9 reconnect-at-launch): a vnode watch on the directory for `connect.json`
    /// (DispatchSource; it watches the nearest existing ancestor until the directory
    /// exists) plus, where AppKit is available, `NSWorkspace.didLaunchApplicationNotification`
    /// for `serverBundleId` followed by a ≤ 10 s discovery poll. Yields the current discovery
    /// first if the server is already up, then again whenever the discovery file reappears
    /// or changes (a restarted server). Each call is an independent stream; cancel the
    /// consuming task to stop watching.
    public static func serverAppearances(configuration: UnivocalConfiguration) -> AsyncStream<UnivocalDiscovery> {
        let (stream, cont) = AsyncStream<UnivocalDiscovery>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let watcher = ServerAppearanceWatcher(directory: configuration.connectDirectory,
                                              serverBundleId: configuration.serverBundleId,
                                              continuation: cont)
        cont.onTermination = { _ in watcher.cancel() }
        watcher.start()
        return stream
    }
}

/// State for one `serverAppearances` stream; confined to `queue`.
final class ServerAppearanceWatcher: @unchecked Sendable {
    private let directory: URL
    private let serverBundleId: String
    private let continuation: AsyncStream<UnivocalDiscovery>.Continuation
    private let queue = DispatchQueue(label: "com.univocal.connect.appearances")

    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var lastYielded: UnivocalDiscovery?
    private var present = false
    private var pollDeadline: DispatchTime?
    private var cancelled = false
    private var observer: NSObjectProtocol?

    init(directory: URL, serverBundleId: String, continuation: AsyncStream<UnivocalDiscovery>.Continuation) {
        self.directory = directory.standardizedFileURL
        self.serverBundleId = serverBundleId
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            arm()          // watch first, then look, so an appearance in between is not missed
            evaluate()
        }
        #if canImport(AppKit)
        let bundleId = serverBundleId
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == bundleId, let self else { return }
            self.queue.async { self.startPolling() }
        }
        #endif
    }

    func cancel() {
        #if canImport(AppKit)
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        #endif
        queue.async { [self] in
            cancelled = true
            source?.cancel()
            source = nil
        }
    }

    // MARK: Queue-confined

    private func evaluate() {
        guard !cancelled else { return }
        if let d = UnivocalLocator.discovery(in: directory) {
            if !present || d != lastYielded {
                present = true
                lastYielded = d
                continuation.yield(d)
            }
        } else {
            present = false
        }
    }

    /// Watches `directory`, or its nearest existing ancestor until it exists. Re-checks after
    /// each arm: a directory created between the existence check and `open` would otherwise
    /// produce its event on a parent nobody watches any more.
    private func arm() {
        for _ in 0..<16 {
            guard !cancelled else { return }
            var url = directory
            while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
                url.deleteLastPathComponent()
            }
            let path = url.path
            if path == watchedPath, source != nil { return }
            source?.cancel()
            source = nil
            watchedPath = nil
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: queue)
            src.setEventHandler { [weak self] in self?.changed() }
            src.setCancelHandler { close(fd) }
            source = src
            watchedPath = path
            src.resume()
        }
    }

    private func changed() {
        guard let src = source else { return }
        if !src.data.intersection([.delete, .rename]).isEmpty {
            source?.cancel()
            source = nil
            watchedPath = nil
        }
        arm()   // re-arms after deletion, or moves closer once a missing directory appears
        evaluate()
    }

    /// After `didLaunchApplication`: poll every 250 ms for up to 10 s (the listener comes up
    /// before engine work, SPEC §4.3, but not necessarily before the notification).
    private func startPolling() {
        guard !cancelled else { return }
        let alreadyPolling = pollDeadline != nil
        pollDeadline = .now() + 10
        present = false   // a launch is a new appearance even if a stale file looked alive
        guard !alreadyPolling else { return }
        pollTick()
    }

    private func pollTick() {
        guard !cancelled, let deadline = pollDeadline else { return }
        arm()
        evaluate()
        if present || DispatchTime.now() >= deadline {
            pollDeadline = nil
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in self?.pollTick() }
    }
}
