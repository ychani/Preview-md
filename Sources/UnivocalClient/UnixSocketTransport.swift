// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import Network

/// Unix-domain-socket transport over `NWConnection(.unix(path:))` with NDJSON framing (SPEC §3.1).
///
/// All mutable state is confined to `queue`; that is what makes the
/// `@unchecked Sendable` sound.
final class UnixSocketTransport: UnivocalTransport, @unchecked Sendable {
    let kind: UnivocalTransportKind = .unixSocket
    let path: String
    let events: AsyncStream<TransportEvent>

    private let queue = DispatchQueue(label: "com.univocal.connect.unix")
    private let connection: NWConnection
    private let continuation: AsyncStream<TransportEvent>.Continuation
    // queue-confined
    private var framer = NDJSONFramer(maxFrameBytes: inboundMaxFrameBytes)
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var isOpen = false
    private var finished = false

    init(path: String) {
        self.path = path
        let (stream, cont) = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        continuation = cont
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    func open() async throws {
        guard UnivocalPaths.socketPathFits(path) else {
            throw UnivocalError.transport("Socket path exceeds \(UnivocalPaths.maxSocketPathBytes) bytes.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw UnivocalError.transport("No socket at the advertised path (ENOENT).")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.openContinuation = cont
                self.connection.stateUpdateHandler = { [weak self] state in
                    self?.handle(state)
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isOpen = true
            openContinuation?.resume()
            openContinuation = nil
            receive()
        case .waiting(let error), .failed(let error):
            // `.waiting` on a Unix socket means ECONNREFUSED/ENOENT; NWConnection would
            // retry forever. Treat it as a failure and let the client decide.
            fail(UnivocalError.transport("Unix socket: \(error.localizedDescription)"))
        case .cancelled:
            fail(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.framer.push(data) {
                        self.continuation.yield(.message(frame))
                    }
                } catch {
                    self.fail(UnivocalError(code: .protocolError, message: "Server frame exceeds \(inboundMaxFrameBytes) bytes.", fatal: true))
                    return
                }
            }
            if isComplete {
                self.fail(nil)
            } else if let error {
                self.fail(UnivocalError.transport("Unix socket: \(error.localizedDescription)"))
            } else {
                self.receive()
            }
        }
    }

    /// Queue-confined. Finishes the event stream once and tears the connection down.
    private func fail(_ error: UnivocalError?) {
        if let cont = openContinuation {
            openContinuation = nil
            cont.resume(throwing: error ?? UnivocalError.transport("Connection closed while opening."))
        }
        guard !finished else { return }
        finished = true
        if isOpen { continuation.yield(.closed(error)) }
        continuation.finish()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func send(frame: Data) {
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close() {
        queue.async { self.fail(nil) }
    }
}
