// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Network
import XCTest
@testable import UnivocalClient
import UnivocalMock

/// The loopback WebSocket transport (SPEC §3.2), exercised through an in-test
/// `NWListener` WebSocket server that bridges each connection to the mock's
/// Unix socket — so the whole SDK runs over WebSocket against a real server.
final class TransportTests: UnivocalTestCase {

    func testUnixTransportFailsFastForMissingSocket() async throws {
        let t = UnixSocketTransport(path: dir.appendingPathComponent("absent.sock").path)
        do {
            try await t.open()
            XCTFail("expected transportFailure")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .transportFailure)
        }
    }

    func testWebSocketTransportEchoesTextFrames() async throws {
        let bridge = try WebSocketBridge(target: .echo)
        let port = try await bridge.start()
        defer { bridge.stop() }
        let t = WebSocketTransport(url: URL(string: "ws://127.0.0.1:\(port)/connect")!)
        try await t.open()
        let rec = Recorder.start(t.events)
        t.send(frame: try UnivocalWire.frame(["type": "ping", "id": 1]))
        let items = try await rec.wait("echo") { !$0.isEmpty }
        guard case .message(let data) = items[0] else { return XCTFail("expected a message") }
        XCTAssertEqual(try UnivocalWire.decode(data), ["type": "ping", "id": 1], "no trailing newline inside a frame")
        let origin = bridge.lastOrigin
        XCTAssertNil(origin, "the SDK never sends an Origin header")
        t.close()
        try await rec.waitForFinish()
    }

    func testWebSocketRefusesNonLoopbackURL() async throws {
        let t = WebSocketTransport(url: URL(string: "ws://example.com:80/connect")!)
        do {
            try await t.open()
            XCTFail("expected transportFailure")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .transportFailure)
        }
    }

    /// Discovery advertises an unreachable Unix socket and a WebSocket URL: the client
    /// falls back to WebSocket and completes consent, welcome and a session over it.
    func testClientFallsBackToWebSocket() async throws {
        let mock = try await startServer()
        let bridge = try WebSocketBridge(target: .unix(await mock.socketPath))
        let port = try await bridge.start()
        defer { bridge.stop() }

        let wsDir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: wsDir) }
        let d = UnivocalDiscovery(socketPath: wsDir.appendingPathComponent("missing.sock").path,
                                  webSocketURL: URL(string: "ws://127.0.0.1:\(port)/connect"),
                                  pid: getpid(), serverName: "Bridged", serverVersion: "1", serverBundleId: "com.univocal.app")
        try JSONEncoder().encode(d).write(to: UnivocalPaths.discoveryFileURL(in: wsDir))

        let store = InMemoryTokenStore()
        let client = makeClient(store: store, directory: wsDir)
        let info = try await client.connect()
        XCTAssertEqual(info.transport, .webSocket)
        let tokens = await store.all
        XCTAssertEqual(tokens.count, 1)

        let text = "Over the WebSocket."
        let session = try await client.read(ReadRequest(text: text))
        let rec = record(session)
        await mock.advance(words: 10)
        let events = try await rec.waitForFinish()
        XCTAssertEqual(events.words.map { substring(text, $0) }, ["Over", "the", "WebSocket"])
    }

    func testUnixOnlyConfigurationDoesNotUseWebSocket() async throws {
        let wsDir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: wsDir) }
        let d = UnivocalDiscovery(socketPath: wsDir.appendingPathComponent("missing.sock").path,
                                  webSocketURL: URL(string: "ws://127.0.0.1:9/connect"),
                                  pid: getpid(), serverName: "X", serverVersion: "1", serverBundleId: "com.univocal.app")
        try JSONEncoder().encode(d).write(to: UnivocalPaths.discoveryFileURL(in: wsDir))
        let client = makeClient(directory: wsDir) { $0.transports = [.unixSocket] }
        do {
            _ = try await client.connect()
            XCTFail("expected transportFailure")
        } catch let e as UnivocalError {
            XCTAssertEqual(e.code, .transportFailure)
        }
    }
}

/// Minimal loopback WebSocket server: echoes text frames, or bridges each WebSocket
/// connection to a Unix socket (one JSON message per text frame ↔ NDJSON).
final class WebSocketBridge: @unchecked Sendable {
    enum Target { case echo, unix(String) }

    private final class OriginBox: @unchecked Sendable {
        let lock = NSLock()
        var origin: String?
    }

    private let listener: NWListener
    private let target: Target
    private let queue = DispatchQueue(label: "test.ws-bridge")
    private let lock = NSLock()
    private let originBox = OriginBox()
    private var connections: [NWConnection] = []

    /// The `Origin` header of the last upgrade request (nil = none sent).
    var lastOrigin: String? { originBox.lock.withLock { originBox.origin } }

    init(target: Target) throws {
        self.target = target
        let box = originBox
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value
            box.lock.withLock { box.origin = origin }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        final class Once: @unchecked Sendable { var done = false }   // touched only on `queue`
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [listener] state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e):
                    once.done = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }

    private func accept(_ ws: NWConnection) {
        lock.withLock { connections.append(ws) }
        ws.start(queue: queue)
        switch target {
        case .echo:
            pumpWebSocket(ws) { [weak self] data in self?.sendText(data, on: ws) }
        case .unix(let path):
            let unix = NWConnection(to: .unix(path: path), using: .tcp)
            lock.withLock { connections.append(unix) }
            unix.start(queue: queue)
            pumpWebSocket(ws) { data in
                var line = data
                line.append(0x0A)
                unix.send(content: line, completion: .contentProcessed { _ in })
            }
            var framer = NDJSONFramer(maxFrameBytes: 16 * 1_048_576)
            func pumpUnix() {
                unix.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
                    if let data, let frames = try? framer.push(data) {
                        for f in frames { self?.sendText(f, on: ws) }
                    }
                    if done || error != nil { ws.cancel() } else { pumpUnix() }
                }
            }
            pumpUnix()
        }
    }

    private func pumpWebSocket(_ ws: NWConnection, _ onText: @escaping (Data) -> Void) {
        ws.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty { onText(data) }
            if error == nil { self?.pumpWebSocket(ws, onText) }
        }
    }

    private func sendText(_ data: Data, on ws: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        ws.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }
}
