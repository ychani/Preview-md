// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import XCTest
@testable import UnivocalClient
import UnivocalMock

/// A short temp directory so `<dir>/connect.sock` fits `sun_path` (≤ 103 bytes).
/// Never the real `~/Library/Application Support/Univocal*`.
enum TestDirectory {
    static func make() throws -> URL {
        let name = "uc-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        var url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        if !UnivocalPaths.socketPathFits(url.appendingPathComponent(UnivocalPaths.socketFileName).path) {
            url = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        }
        precondition(UnivocalPaths.socketPathFits(url.appendingPathComponent(UnivocalPaths.socketFileName).path))
        precondition(!url.path.contains("Application Support/Univocal"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }
}

struct WaitTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Records an `AsyncStream` and lets tests await a condition instead of sleeping.
actor Recorder<E: Sendable> {
    private(set) var items: [E] = []
    private(set) var finished = false
    private var waiters: [(id: UUID, predicate: @Sendable ([E], Bool) -> Bool, cont: CheckedContinuation<Void, Error>)] = []

    static func start(_ stream: AsyncStream<E>) -> Recorder<E> {
        let r = Recorder<E>()
        Task {
            for await e in stream { await r.append(e) }
            await r.finish()
        }
        return r
    }

    private func append(_ e: E) {
        items.append(e)
        resumeSatisfied()
    }

    private func finish() {
        finished = true
        resumeSatisfied()
    }

    private func resumeSatisfied() {
        waiters.removeAll { w in
            guard w.predicate(items, finished) else { return false }
            w.cont.resume()
            return true
        }
    }

    /// Waits until `predicate(items)` holds; throws `WaitTimeout` after `timeout`.
    @discardableResult
    func wait(_ what: String = "condition", timeout: Duration = .seconds(5),
              until predicate: @escaping @Sendable ([E]) -> Bool) async throws -> [E] {
        try await waitRaw(what, timeout: timeout) { items, _ in predicate(items) }
    }

    /// Waits until the stream finished.
    @discardableResult
    func waitForFinish(timeout: Duration = .seconds(5)) async throws -> [E] {
        try await waitRaw("stream to finish", timeout: timeout) { _, done in done }
    }

    private func waitRaw(_ what: String, timeout: Duration,
                         _ predicate: @escaping @Sendable ([E], Bool) -> Bool) async throws -> [E] {
        if predicate(items, finished) { return items }
        let id = UUID()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            waiters.append((id, predicate, cont))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id, what)
            }
        }
        return items
    }

    private func expire(_ id: UUID, _ what: String) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: i)
        w.cont.resume(throwing: WaitTimeout(description: "timed out waiting for \(what); got \(items.count) items: \(items.suffix(12))"))
    }
}

extension Array where Element == ReadingEvent {
    var words: [Range<Int>] { compactMap { if case .word(let r) = $0 { return r } else { return nil } } }
    var sentences: [Range<Int>] { compactMap { if case .sentence(let r) = $0 { return r } else { return nil } } }
    var states: [PlaybackState] { compactMap { if case .state(let s, _) = $0 { return s } else { return nil } } }
    var ended: (EndReason, String?)? {
        for e in self { if case .ended(let r, let by) = e { return (r, by) } }
        return nil
    }
    var hasEnded: Bool { ended != nil }
    var errors: [UnivocalError] { compactMap { if case .error(let e) = $0 { return e } else { return nil } } }
}

func substring(_ text: String, _ r: Range<Int>) -> String {
    guard let sr = UTF16Offsets.range(r, in: text) else { return "<out of range>" }
    return String(text[sr])
}

/// Base class: one temp `<ConnectDir>`, servers and clients torn down after each test.
class UnivocalTestCase: XCTestCase {
    var dir: URL!
    private var servers: [MockServer] = []
    private var clients: [UnivocalClient] = []
    private var raws: [RawConnectClient] = []

    override func setUp() async throws {
        try await super.setUp()
        dir = try TestDirectory.make()
    }

    override func tearDown() async throws {
        for c in clients { await c.disconnect() }
        for r in raws { r.close() }
        for s in servers { await s.stop() }
        clients.removeAll()
        servers.removeAll()
        raws.removeAll()
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    /// Defaults for tests: no loading delay, manual clock (words advance on `advance(words:)`).
    func startServer(in directory: URL? = nil, _ configure: (inout MockBehaviour) -> Void = { _ in }) async throws -> MockServer {
        var b = MockBehaviour()
        b.loadingDelay = .zero
        b.wordsPerMinute = 0
        configure(&b)
        let s = MockServer(directory: directory ?? dir, behaviour: b)
        try await s.start()
        servers.append(s)
        return s
    }

    func makeClient(id: String = "com.example.tests", name: String = "Tests",
                    store: InMemoryTokenStore? = nil, directory: URL? = nil,
                    _ configure: (inout UnivocalConfiguration) -> Void = { _ in }) -> UnivocalClient {
        var c = UnivocalConfiguration(client: .init(id: id, name: name, version: "1.0", bundleId: "com.example.tests"),
                                      environment: [:])
        c.connectDirectory = directory ?? dir
        c.tokenStore = store ?? InMemoryTokenStore()
        c.appLocator = { _ in nil }   // never consult LaunchServices
        c.launcher = { _, _ in throw UnivocalError(code: .launchTimedOut, message: "tests never launch apps") }
        c.consentTimeout = .seconds(5)
        c.launchTimeout = .seconds(2)
        configure(&c)
        let client = UnivocalClient(configuration: c)
        clients.append(client)
        return client
    }

    func raw(_ server: MockServer) async throws -> RawConnectClient {
        let r = try RawConnectClient(path: await server.socketPath)
        raws.append(r)
        return r
    }

    static func hello(id: String = "com.example.raw", name: String = "Raw", token: String? = nil,
                      versions: [Int] = [1], proto: String = "univocal-connect",
                      capabilities: [String] = ["word-events", "sentence-events"]) -> JSONObject {
        var m: JSONObject = [
            "type": "hello", "protocol": .string(proto), "versions": .array(versions.map { .int($0) }),
            "client": ["id": .string(id), "name": .string(name), "version": "1"],
            "capabilities": .array(capabilities.map { .string($0) }),
        ]
        if let token { m["token"] = .string(token) }
        return m
    }

    /// A raw connection that completed hello (auto-grant server) and received `welcome`.
    func rawWelcomed(_ server: MockServer, id: String = "com.example.raw", token: String? = nil,
                     capabilities: [String] = ["word-events", "sentence-events"]) async throws -> RawConnectClient {
        let r = try await raw(server)
        try r.send(Self.hello(id: id, token: token, capabilities: capabilities))
        _ = try await r.expectAsync("welcome", timeout: 5)
        return r
    }

    /// Records a session's events.
    func record(_ session: ReadingSession) -> Recorder<ReadingEvent> {
        Recorder.start(session.events)
    }
}
