// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation

/// Loopback WebSocket transport (SPEC §3.2) over `URLSessionWebSocketTask`.
///
/// One JSON message per text frame; no `Origin` header is set (URLSession does
/// not add one), so a conformant server accepts the upgrade. Tested against an
/// in-process `NWListener` WebSocket echo server, not yet against Univocal.
final class WebSocketTransport: NSObject, UnivocalTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    let kind: UnivocalTransportKind = .webSocket
    let url: URL
    let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    // guarded by `lock`
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var isOpen = false
    private var finished = false

    init(url: URL) {
        self.url = url
        let (stream, cont) = AsyncStream<TransportEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        continuation = cont
        super.init()
    }

    func open() async throws {
        guard let host = url.host, host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            throw UnivocalError.transport("Refusing a non-loopback WebSocket URL.")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: url)
            task.maximumMessageSize = inboundMaxFrameBytes
            lock.withLock {
                self.session = session
                self.task = task
                self.openContinuation = cont
            }
            task.resume()
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let cont: CheckedContinuation<Void, Error>? = lock.withLock {
            isOpen = true
            defer { openContinuation = nil }
            return openContinuation
        }
        cont?.resume()
        receive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error.map { UnivocalError.transport("WebSocket: \($0.localizedDescription)") })
    }

    private func receive() {
        guard let task = lock.withLock({ self.task }) else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                var data = Data(text.utf8)
                while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
                if !data.isEmpty { self.continuation.yield(.message(data)) }
                self.receive()
            case .success(.data):
                self.finish(UnivocalError(code: .protocolError, message: "Binary WebSocket frame from server.", fatal: true))
            case .success:
                self.receive()
            case .failure(let error):
                self.finish(UnivocalError.transport("WebSocket: \(error.localizedDescription)"))
            }
        }
    }

    private func finish(_ error: UnivocalError?) {
        let (cont, wasOpen, alreadyFinished, task, session): (CheckedContinuation<Void, Error>?, Bool, Bool, URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            let r = (openContinuation, isOpen, finished, self.task, self.session)
            openContinuation = nil
            finished = true
            self.task = nil
            self.session = nil
            return r
        }
        cont?.resume(throwing: error ?? UnivocalError.transport("WebSocket closed while opening."))
        guard !alreadyFinished else { return }
        if wasOpen { continuation.yield(.closed(error)) }
        continuation.finish()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    func send(frame: Data) {
        guard let task = lock.withLock({ self.task }) else { return }
        var data = frame
        if data.last == 0x0A { data.removeLast() }
        task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error { self?.finish(UnivocalError.transport("WebSocket send: \(error.localizedDescription)")) }
        }
    }

    func close() {
        finish(nil)
    }
}
