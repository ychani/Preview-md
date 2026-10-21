// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import UnivocalClient

/// A deliberately low-level, blocking NDJSON client over the Unix socket.
///
/// Used by the conformance probe and by tests that must send malformed or
/// oversize frames, or must *not* read (slow consumer). Not thread-safe: use one
/// instance from one task at a time. The `async` variants run the blocking call
/// on a global queue so they never park a Swift-concurrency thread.
public final class RawConnectClient: @unchecked Sendable {
    public enum RawError: Error, Equatable, CustomStringConvertible {
        case connectFailed(Int32)
        case pathTooLong
        case writeFailed(Int32)
        case closed
        case timeout(String)

        public var description: String {
            switch self {
            case .connectFailed(let e): return "connect failed: \(String(cString: strerror(e)))"
            case .pathTooLong: return "socket path exceeds \(UnivocalPaths.maxSocketPathBytes) bytes"
            case .writeFailed(let e): return "write failed: \(String(cString: strerror(e)))"
            case .closed: return "connection closed by peer"
            case .timeout(let what): return "timed out waiting for \(what)"
            }
        }
    }

    public let path: String
    private var fd: Int32
    private var framer = NDJSONFramer(maxFrameBytes: 64 * 1_048_576)
    private var inbox: [JSONObject] = []
    /// `true` once the peer closed (EOF or reset).
    public private(set) var peerClosed = false
    /// Count of frames that were not valid JSON objects.
    public private(set) var undecodableFrames = 0

    public init(path: String) throws {
        guard UnivocalPaths.socketPathFits(path) else { throw RawError.pathTooLong }
        self.path = path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RawError.connectFailed(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            fd = -1
            throw RawError.connectFailed(e)
        }
    }

    deinit { close() }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Shrinks the kernel receive buffer (slow-consumer tests).
    public func setReceiveBuffer(bytes: Int32) {
        var v = bytes
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &v, socklen_t(MemoryLayout<Int32>.size))
    }

    // MARK: Sending

    public func send(_ message: JSONObject) throws {
        try sendRaw(UnivocalWire.frame(message))
    }

    /// Writes bytes verbatim (malformed JSON, `\r\n`, oversize frames…).
    public func sendRaw(_ data: Data) throws {
        guard fd >= 0 else { throw RawError.closed }
        try data.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n > 0 { off += n; continue }
                if n < 0, errno == EINTR { continue }
                throw RawError.writeFailed(errno)
            }
        }
    }

    public func sendRaw(_ string: String) throws {
        try sendRaw(Data(string.utf8))
    }

    // MARK: Receiving

    /// The next message, or `nil` after `timeout` seconds. Throws `.closed` once the
    /// peer has closed and every buffered message was consumed.
    public func next(timeout: TimeInterval) throws -> JSONObject? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !inbox.isEmpty { return inbox.removeFirst() }
            if peerClosed || fd < 0 { throw RawError.closed }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            try fill(timeout: remaining)
        }
    }

    /// Reads until a message of `type` arrives (optionally matching `where`); other
    /// messages are passed to `others` (default: discarded).
    public func expect(_ type: String, timeout: TimeInterval,
                       where predicate: (JSONObject) -> Bool = { _ in true },
                       others: (JSONObject) -> Void = { _ in }) throws -> JSONObject {
        try first(timeout: timeout, describing: type, matching: { $0.messageType == type && predicate($0) }, others: others)
    }

    /// The reply (`ok`, `error`, `pong`, `voices`…) carrying `id`.
    public func reply(to id: JSONValue, timeout: TimeInterval, others: (JSONObject) -> Void = { _ in }) throws -> JSONObject {
        try first(timeout: timeout, describing: "the reply to id \(id)", matching: { $0["id"] == id }, others: others)
    }

    private func first(timeout: TimeInterval, describing what: String, matching: (JSONObject) -> Bool,
                       others: (JSONObject) -> Void) throws -> JSONObject {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let msg = try next(timeout: remaining) else { throw RawError.timeout(what) }
            if matching(msg) { return msg }
            others(msg)
        }
    }

    /// Everything until the peer closes (or `timeout`). Returns `(messages, closed)`.
    public func readUntilClosed(timeout: TimeInterval) -> (messages: [JSONObject], closed: Bool) {
        var out: [JSONObject] = []
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return (out, false) }
            do {
                guard let m = try next(timeout: remaining) else { return (out, false) }
                out.append(m)
            } catch {
                return (out, true)
            }
        }
    }

    /// Messages that arrive within `window` seconds (non-blocking-ish drain).
    public func drain(window: TimeInterval) -> [JSONObject] {
        var out: [JSONObject] = []
        let deadline = Date().addingTimeInterval(window)
        while let m = try? next(timeout: max(0, deadline.timeIntervalSinceNow)) { out.append(m) }
        return out
    }

    private func fill(timeout: TimeInterval) throws {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ms = Int32(min(max(timeout * 1000, 0), 600_000).rounded(.up))
        let r = poll(&pfd, 1, ms)
        if r == 0 { return }
        if r < 0 {
            if errno == EINTR { return }
            peerClosed = true
            return
        }
        var buf = [UInt8](repeating: 0, count: 65_536)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            let frames = (try? framer.push(Data(buf[0..<n]))) ?? []
            for f in frames {
                if let m = try? UnivocalWire.decode(f) { inbox.append(m) } else { undecodableFrames += 1 }
            }
        } else if n == 0 {
            peerClosed = true
        } else if errno != EINTR, errno != EAGAIN {
            peerClosed = true
        }
    }

    // MARK: Async wrappers (run the blocking call off the cooperative pool)

    public func nextAsync(timeout: TimeInterval) async throws -> JSONObject? {
        try await offload { try self.next(timeout: timeout) }
    }

    public func expectAsync(_ type: String, timeout: TimeInterval,
                            where predicate: @escaping @Sendable (JSONObject) -> Bool = { _ in true }) async throws -> JSONObject {
        try await offload { try self.expect(type, timeout: timeout, where: predicate) }
    }

    public func readUntilClosedAsync(timeout: TimeInterval) async -> (messages: [JSONObject], closed: Bool) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async { cont.resume(returning: self.readUntilClosed(timeout: timeout)) }
        }
    }

    public func drainAsync(window: TimeInterval) async -> [JSONObject] {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async { cont.resume(returning: self.drain(window: window)) }
        }
    }

    private func offload<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }
}
