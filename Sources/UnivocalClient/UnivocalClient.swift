// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import os

// MARK: - Public connection types

public struct UnivocalServerInfo: Sendable, Equatable {
    public var name: String
    public var version: String
    public var bundleId: String
    public var protocolVersion: Int
    public var capabilities: Set<String>
    public var maxFrameBytes: Int
    public var maxTextBytes: Int
    public var rateRange: ClosedRange<Double>
    /// How Univocal identified this client, e.g. "unverified:com.narnarlabs.previewmd".
    public var grantIdentity: String
    public var transport: UnivocalTransportKind

    public init(name: String, version: String, bundleId: String, protocolVersion: Int, capabilities: Set<String>,
                maxFrameBytes: Int, maxTextBytes: Int, rateRange: ClosedRange<Double>, grantIdentity: String,
                transport: UnivocalTransportKind) {
        self.name = name
        self.version = version
        self.bundleId = bundleId
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.maxFrameBytes = maxFrameBytes
        self.maxTextBytes = maxTextBytes
        self.rateRange = rateRange
        self.grantIdentity = grantIdentity
        self.transport = transport
    }
}

public enum UnivocalConnectionState: Sendable, Equatable {
    /// Initial / after `disconnect()` or a failure; see `lastError` on the client.
    case disconnected
    /// App launched, waiting for the discovery file.
    case launching
    case connecting
    /// `consentPending` received; show "Waiting for approval in Univocal…".
    case awaitingConsent
    case connected(UnivocalServerInfo)
}

// MARK: - Client

/// A Univocal Connect client (SPEC v1). One instance per app is typical.
///
/// Threading: an `actor`; transport I/O runs on private dispatch queues and
/// nothing touches the main thread. Session events arrive on each
/// `ReadingSession.events` stream; consumers hop to the MainActor themselves.
public actor UnivocalClient {
    public nonisolated let configuration: UnivocalConfiguration

    public private(set) var state: UnivocalConnectionState = .disconnected
    public private(set) var lastError: UnivocalError?

    private nonisolated let broadcaster = StateBroadcaster()
    private var link: Link?
    private var nextLinkId = 1
    private var nextRequestId = 1
    private var connectTask: Task<UnivocalServerInfo, Error>?
    /// Set on `unauthorized{revoked}`: connect() refuses to re-prompt until then (SPEC §5.3).
    private var revokedUntil: Date?

    /// SDK chunk size (UTF-8 bytes) for long texts (SPEC §8).
    static let chunkUTF8Bytes = 512 * 1024
    static let revocationHold: TimeInterval = 600

    public init(configuration: UnivocalConfiguration) {
        self.configuration = configuration
    }

    /// Each call returns a new independent stream that yields the current state first.
    public nonisolated func stateUpdates() -> AsyncStream<UnivocalConnectionState> {
        broadcaster.makeStream()
    }

    // MARK: Connect / disconnect

    /// Discovers, optionally launches, connects, performs hello + consent, returns on `welcome`.
    /// Idempotent: returns the existing server info if already connected.
    ///
    /// A live discovery file is sufficient: when Univocal (or a mock) is already
    /// running, the LaunchServices installation check is skipped.
    public func connect(launchIfNeeded: Bool = true) async throws -> UnivocalServerInfo {
        if case .connected(let info) = state, let link, !link.tornDown { return info }
        if let task = connectTask { return try await task.value }
        if let until = revokedUntil {
            if Date() < until {
                throw UnivocalError(code: .unauthorized,
                                    message: "Univocal revoked this app's access. Try again later.",
                                    fatal: true, reason: "revoked")
            }
            revokedUntil = nil
        }
        let task = Task { try await self.performConnect(launchIfNeeded: launchIfNeeded) }
        connectTask = task
        defer { connectTask = nil }
        return try await task.value
    }

    /// Ends any live session locally (its stream gets `.ended(.stopped, by: nil)`; the
    /// server ends it silently when the connection closes) and closes the transport.
    public func disconnect() async {
        connectTask?.cancel()
        if let link {
            teardown(link, error: .disconnected("Disconnected by the client."), byUser: true)
        }
        setState(.disconnected)
    }

    /// Forgets the stored token (next connect re-prompts in Univocal) and disconnects.
    public func forgetAuthorization() async throws {
        revokedUntil = nil
        await disconnect()
        try await configuration.tokenStore.setToken(nil, forServer: configuration.serverBundleId)
        log("token forgotten")
    }

    // MARK: Sessions

    /// Starts a reading session. Connects first if needed (same rules as `connect()`).
    /// Returns after the server's `ok` (and after every chunk of a long text was accepted);
    /// the first event is `.state(.loading)`.
    public func read(_ request: ReadRequest) async throws -> ReadingSession {
        let info = try await connect()
        guard let link, !link.tornDown else { throw UnivocalError.disconnected() }
        let sid = request.sessionId
        guard !request.text.isEmpty else {
            throw UnivocalError(code: .invalidArgument, message: "Nothing to read: the text is empty.", sessionId: sid)
        }
        let utf16Count = request.text.utf16.count
        guard (0...utf16Count).contains(request.startOffset) else {
            throw UnivocalError(code: .invalidOffset, message: "startOffset \(request.startOffset) is outside 0…\(utf16Count).", sessionId: sid)
        }
        let utf8Count = request.text.utf8.count
        guard utf8Count <= info.maxTextBytes else {
            throw UnivocalError(code: .textTooLarge, message: "The text is \(utf8Count) bytes; Univocal accepts at most \(info.maxTextBytes).", sessionId: sid)
        }
        if let existing = link.sessions[sid], !existing.isEnded {
            throw UnivocalError(code: .sessionExists, message: "Session \(sid) is still live.", sessionId: sid)
        }

        let budget = max(1024, min(Self.chunkUTF8Bytes, info.maxFrameBytes / 2))
        var pieces = TextChunker.chunks(request.text, maxUTF8: budget)
        let session = ReadingSession(id: sid, textUTF16Count: utf16Count, client: self)
        link.sessions[sid] = session.sink
        log("read session=\(sid) utf16=\(utf16Count) utf8=\(utf8Count) chunks=\(pieces.count)")

        var index = 0
        do {
            while index < pieces.count {
                let more = index < pieces.count - 1
                var msg: JSONObject
                if index == 0 {
                    msg = ["type": "read", "sessionId": .string(sid), "text": .string(pieces[0]),
                           "preempt": .bool(request.preempt), "more": .bool(more)]
                    if let lang = request.language { msg["lang"] = .string(lang) }
                    if let voice = request.voice { msg["voice"] = .string(voice) }
                    if let rate = request.rate { msg["rate"] = .double(rate) }
                    if request.startOffset != 0 { msg["startOffset"] = .int(request.startOffset) }
                    if request.showPanel, info.capabilities.contains("panel") { msg["ui"] = "panel" }
                    if let title = request.title { msg["meta"] = .object(["title": .string(title)]) }
                } else {
                    msg = ["type": "append", "sessionId": .string(sid), "text": .string(pieces[index]), "more": .bool(more)]
                }
                do {
                    _ = try await self.request(msg, on: link)
                    index += 1
                } catch let e as UnivocalError where e.code == .textTooLarge && pieces[index].utf8.count > 1024 {
                    // JSON escaping inflated this chunk past maxFrameBytes: split it and retry.
                    let half = TextChunker.chunks(pieces[index], maxUTF8: max(512, pieces[index].utf8.count / 2))
                    pieces.replaceSubrange(index...index, with: half)
                }
            }
        } catch {
            if link.sessions[sid] === session.sink { link.sessions[sid] = nil }
            if index > 0, !session.isEnded, !link.tornDown,
               let frame = try? UnivocalWire.frame(["type": "stop", "sessionId": .string(sid)]) {
                link.transport.send(frame: frame)   // best effort: the server accepted the first chunk
            }
            session.sink.yield(.ended(.error, by: nil))
            throw error
        }
        return session
    }

    /// The server's voices. Throws `invalidArgument` if the server lacks capability `voices`.
    public func listVoices() async throws -> [UnivocalVoice] {
        let info = try await connect()
        guard info.capabilities.contains("voices") else {
            throw UnivocalError(code: .invalidArgument, message: "This Univocal does not offer a voice list.")
        }
        guard let link else { throw UnivocalError.disconnected() }
        let reply = try await request(["type": "listVoices"], on: link)
        return (reply.array("voices") ?? []).compactMap { v in
            guard let o = v.objectValue, let id = o.string("id") else { return nil }
            return UnivocalVoice(id: id, name: o.string("name") ?? id, lang: o.string("lang"))
        }
    }

    /// Round-trip time of a `ping`.
    public func ping() async throws -> Duration {
        _ = try await connect()
        guard let link else { throw UnivocalError.disconnected() }
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await request(["type": "ping"], on: link)
        return clock.now - start
    }

    // MARK: Internals used by ReadingSession

    func control(_ session: ReadingSession, type: String, fields: JSONObject = [:]) async throws {
        guard !session.isEnded else {
            throw UnivocalError(code: .sessionEnded, message: "The session has ended.", sessionId: session.id)
        }
        guard let link, !link.tornDown, link.sessions[session.id] === session.sink else {
            throw UnivocalError(code: .sessionEnded, message: "The session is no longer live.", sessionId: session.id)
        }
        var msg = fields
        msg["type"] = .string(type)
        msg["sessionId"] = .string(session.id)
        _ = try await request(msg, on: link)
    }

    // MARK: - Connection establishment

    private func performConnect(launchIfNeeded: Bool) async throws -> UnivocalServerInfo {
        do {
            return try await establish(launchIfNeeded: launchIfNeeded)
        } catch {
            let e: UnivocalError
            if let u = error as? UnivocalError {
                e = u
            } else if error is CancellationError {
                e = .disconnected("Connecting was cancelled.")
            } else {
                e = .transport(error.localizedDescription)
            }
            lastError = e
            setState(.disconnected)
            log("connect failed code=\(e.code.rawValue) reason=\(e.reason ?? "-")")
            throw e
        }
    }

    private func establish(launchIfNeeded: Bool) async throws -> UnivocalServerInfo {
        setState(.connecting)
        let dir = configuration.connectDirectory
        let clock = ContinuousClock()
        var deadline: ContinuousClock.Instant?
        var discovery = UnivocalLocator.discovery(in: dir)
        if discovery == nil {
            guard let appURL = configuration.appLocator(configuration.serverBundleId) else {
                throw UnivocalError(code: .notInstalled, message: "Univocal is not installed.")
            }
            guard launchIfNeeded else {
                throw UnivocalError(code: .notRunning, message: "Univocal is not running.")
            }
            setState(.launching)
            log("launching server")
            let dl = clock.now.advanced(by: configuration.launchTimeout)
            deadline = dl
            do {
                try await configuration.launcher(appURL, configuration.serverBundleId)
            } catch let e as UnivocalError {
                throw e
            } catch {
                throw UnivocalError(code: .launchTimedOut, message: "Univocal did not start: \(error.localizedDescription)")
            }
            while true {
                if let d = UnivocalLocator.discovery(in: dir) { discovery = d; break }
                if clock.now >= dl {
                    throw UnivocalError(code: .launchTimedOut, message: "Univocal did not start.")
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            setState(.connecting)
        }
        guard let discovery else { throw UnivocalError(code: .notRunning, message: "Univocal is not running.") }
        guard discovery.versions.contains(where: UnivocalWire.protocolVersions.contains) else {
            throw UnivocalError(code: .unsupportedVersion,
                                message: "Univocal speaks protocol versions \(discovery.versions); this app needs \(UnivocalWire.protocolVersions).",
                                fatal: true)
        }
        let transport = try await openTransport(discovery, deadline: deadline)
        return try await handshake(over: transport)
    }

    private func openTransport(_ discovery: UnivocalDiscovery, deadline: ContinuousClock.Instant?) async throws -> any UnivocalTransport {
        let clock = ContinuousClock()
        var delay = Duration.milliseconds(100)
        while true {
            var lastError: UnivocalError?
            for kind in configuration.transports {
                let transport: any UnivocalTransport
                switch kind {
                case .unixSocket:
                    transport = UnixSocketTransport(path: discovery.socketPath)
                case .webSocket:
                    guard let url = discovery.webSocketURL else { continue }
                    transport = WebSocketTransport(url: url)
                }
                do {
                    try await transport.open()
                    log("transport open kind=\(kind.rawValue)")
                    return transport
                } catch {
                    transport.close()
                    lastError = (error as? UnivocalError) ?? .transport(error.localizedDescription)
                }
            }
            guard let deadline, clock.now.advanced(by: delay) < deadline else {
                throw lastError ?? UnivocalError.transport("No usable transport to Univocal.")
            }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(1))
        }
    }

    private func handshake(over transport: any UnivocalTransport) async throws -> UnivocalServerInfo {
        let linkId = nextLinkId
        nextLinkId += 1
        let link = Link(id: linkId, transport: transport)
        self.link = link
        let events = transport.events
        link.readerTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.receive(event, linkId: linkId)
            }
        }

        let token: String?
        do {
            token = try await configuration.tokenStore.token(forServer: configuration.serverBundleId)
        } catch {
            log("token store read failed")
            token = nil
        }
        guard self.link === link, !link.tornDown else { throw UnivocalError.disconnected() }

        let c = configuration.client
        var client: JSONObject = ["id": .string(c.id), "name": .string(c.name), "version": .string(c.version)]
        if let b = c.bundleId { client["bundleId"] = .string(b) }
        var hello: JSONObject = [
            "type": "hello",
            "protocol": .string(UnivocalWire.protocolName),
            "versions": .array(UnivocalWire.protocolVersions.map { .int($0) }),
            "client": .object(client),
            "capabilities": .array(configuration.clientCapabilities.sorted().map { .string($0) }),
        ]
        if let token { hello["token"] = .string(token) }
        let frame = try encodeFrame(hello, limit: UnivocalWire.minimumMaxFrameBytes)
        log("hello client=\(c.id) token=\(token == nil ? "absent" : "present")")

        let timeout = configuration.consentTimeout
        link.timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.handshakeTimedOut(linkId: linkId)
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UnivocalServerInfo, Error>) in
            link.handshake = cont
            link.transport.send(frame: frame)
        }
    }

    private func handshakeTimedOut(linkId: Int) {
        guard let link, link.id == linkId, link.handshake != nil else { return }
        let err: UnivocalError = state == .awaitingConsent
            ? UnivocalError(code: .consentTimedOut, message: "No answer from the approval prompt in Univocal.", fatal: true, reason: "timeout")
            : UnivocalError.transport("Univocal did not answer the handshake.")
        teardown(link, error: err, byUser: false)
    }

    // MARK: - Inbound

    private func receive(_ event: TransportEvent, linkId: Int) async {
        guard let link, link.id == linkId, !link.tornDown else { return }
        switch event {
        case .closed(let error):
            let err = link.fatalError ?? error ?? UnivocalError.disconnected()
            teardown(link, error: err, byUser: false)
        case .message(let data):
            guard let msg = try? UnivocalWire.decode(data), let type = msg.messageType else {
                log("ignoring malformed server frame bytes=\(data.count)")
                return
            }
            await dispatch(msg, type: type, link: link)
        }
    }

    private func dispatch(_ msg: JSONObject, type: String, link: Link) async {
        switch type {
        case "consentPending":
            if link.handshake != nil {
                log("consent pending")
                setState(.awaitingConsent)
            }
        case "consentGranted":
            log("consent granted")
            if let token = msg.string("token") {
                do {
                    try await configuration.tokenStore.setToken(token, forServer: configuration.serverBundleId)
                } catch {
                    log("token store write failed")
                }
            }
        case "consentDenied":
            let reason = msg.string("reason") ?? "user"
            log("consent denied reason=\(reason)")
            let err = UnivocalError(code: .consentDenied, message: Self.denialMessage(reason), fatal: true, reason: reason)
            link.fatalError = err
            teardown(link, error: err, byUser: false)
        case "welcome":
            handleWelcome(msg, link: link)
        case "ok", "pong", "voices":
            if let id = msg.int("id"), let cont = link.pending.removeValue(forKey: id) {
                cont.resume(returning: msg)
            }
        case "error":
            await handleError(msg, link: link)
        case "ping":
            var pong: JSONObject = ["type": "pong"]
            if let id = msg["id"] { pong["id"] = id }
            if let frame = try? UnivocalWire.frame(pong) { link.transport.send(frame: frame) }
        case "state", "sentence", "word", "progress", "rate", "ended":
            routeSessionEvent(msg, type: type, link: link)
        default:
            break   // unknown types are ignored (SPEC §3.3, CONFORMANCE C3)
        }
    }

    private func handleWelcome(_ msg: JSONObject, link: Link) {
        let version = msg.int("version") ?? 0
        guard UnivocalWire.protocolVersions.contains(version) else {
            let err = UnivocalError(code: .unsupportedVersion, message: "Univocal answered with protocol version \(version).", fatal: true)
            link.fatalError = err
            teardown(link, error: err, byUser: false)
            return
        }
        let server = msg.object("server") ?? [:]
        let limits = msg.object("limits") ?? [:]
        let rate = limits.object("rate") ?? [:]
        let lo = rate.double("min") ?? 0.25
        let hi = rate.double("max") ?? 4.0
        let info = UnivocalServerInfo(
            name: server.string("name") ?? "Univocal",
            version: server.string("version") ?? "",
            bundleId: server.string("bundleId") ?? configuration.serverBundleId,
            protocolVersion: version,
            capabilities: Set((msg.array("capabilities") ?? []).compactMap(\.stringValue)),
            maxFrameBytes: limits.int("maxFrameBytes") ?? UnivocalWire.minimumMaxFrameBytes,
            maxTextBytes: limits.int("maxTextBytes") ?? 8 * 1_048_576,
            rateRange: min(lo, hi)...max(lo, hi),
            grantIdentity: msg.object("grant")?.string("identity") ?? "",
            transport: link.transport.kind
        )
        link.info = info
        link.maxFrameBytes = info.maxFrameBytes
        lastError = nil
        setState(.connected(info))
        log("welcome version=\(version) identity=\(info.grantIdentity) transport=\(info.transport.rawValue)")
        if let cont = link.handshake {
            link.handshake = nil
            link.timeoutTask?.cancel()
            cont.resume(returning: info)
        }
    }

    private func handleError(_ msg: JSONObject, link: Link) async {
        let err = UnivocalError(wire: msg)
        log("server error code=\(err.code.rawValue) fatal=\(err.fatal) reason=\(err.reason ?? "-")")
        if err.code == .unauthorized, err.reason == "revoked" {
            revokedUntil = Date().addingTimeInterval(Self.revocationHold)
            do {
                try await configuration.tokenStore.setToken(nil, forServer: configuration.serverBundleId)
            } catch {
                log("token store delete failed")
            }
        }
        if err.fatal { link.fatalError = err }
        if let id = msg.int("id"), let cont = link.pending.removeValue(forKey: id) {
            cont.resume(throwing: err)
        } else if let sid = err.sessionId, let sink = link.sessions[sid] {
            sink.yield(.error(err))
        } else if link.handshake != nil, err.fatal {
            teardown(link, error: err, byUser: false)
        }
    }

    private func routeSessionEvent(_ msg: JSONObject, type: String, link: Link) {
        guard let sid = msg.string("sessionId"), let sink = link.sessions[sid] else { return }
        switch type {
        case "state":
            guard let s = PlaybackState(rawValue: msg.string("state") ?? "") else { return }
            sink.yield(.state(s, detail: msg.string("detail")))
        case "sentence", "word":
            guard let a = msg.int("start"), let b = msg.int("end"), a >= 0, a < b, b <= sink.textUTF16Count else {
                log("dropping out-of-range \(type) session=\(sid)")
                return
            }
            sink.yield(type == "word" ? .word(a..<b) : .sentence(a..<b))
        case "progress":
            if let o = msg.int("offset") { sink.yield(.progress(offset: o)) }
        case "rate":
            if let r = msg.double("rate") { sink.yield(.rate(r)) }
        case "ended":
            let reason = EndReason(rawValue: msg.string("reason") ?? "") ?? .error
            log("ended session=\(sid) reason=\(reason.rawValue)")
            sink.yield(.ended(reason, by: msg.string("by")))
            link.sessions[sid] = nil
        default:
            break
        }
    }

    // MARK: - Outbound

    private func request(_ message: JSONObject, on link: Link) async throws -> JSONObject {
        guard !link.tornDown else { throw link.fatalError ?? UnivocalError.disconnected() }
        let id = nextRequestId
        nextRequestId += 1
        var msg = message
        msg["id"] = .int(id)
        let frame = try encodeFrame(msg, limit: link.maxFrameBytes)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONObject, Error>) in
            link.pending[id] = cont
            link.transport.send(frame: frame)
        }
    }

    private func encodeFrame(_ msg: JSONObject, limit: Int) throws -> Data {
        let frame: Data
        do {
            frame = try UnivocalWire.frame(msg)
        } catch {
            throw UnivocalError(code: .invalidArgument, message: "Message could not be encoded as JSON.")
        }
        guard frame.count <= limit else {
            throw UnivocalError(code: .textTooLarge, message: "A \(frame.count)-byte frame exceeds the \(limit)-byte limit.",
                                sessionId: msg.string("sessionId"))
        }
        return frame
    }

    // MARK: - Teardown & state

    private func teardown(_ link: Link, error: UnivocalError, byUser: Bool) {
        let wasCurrent = self.link === link
        if wasCurrent { self.link = nil }
        guard !link.tornDown else { return }
        link.tornDown = true
        link.timeoutTask?.cancel()
        link.readerTask?.cancel()
        link.transport.close()
        if let cont = link.handshake {
            link.handshake = nil
            cont.resume(throwing: error)
        }
        let pending = link.pending
        link.pending.removeAll()
        for (_, cont) in pending { cont.resume(throwing: error) }
        let sessions = link.sessions
        link.sessions.removeAll()
        for (sid, sink) in sessions {
            if byUser {
                sink.yield(.ended(.stopped, by: nil))
            } else {
                var e = error
                if e.code != .unauthorized, e.code != .slowConsumer, e.code != .protocolError { e.code = .disconnected }
                e.sessionId = sid
                sink.yield(.error(e))
                sink.yield(.ended(.error, by: nil))
            }
        }
        if !byUser { lastError = error }
        log("link closed code=\(error.code.rawValue) byUser=\(byUser)")
        if wasCurrent { setState(.disconnected) }
    }

    private func setState(_ new: UnivocalConnectionState) {
        guard state != new else { return }
        state = new
        broadcaster.set(new)
    }

    private func log(_ line: String) {
        configuration.logger?("[UnivocalClient] " + line)
    }

    private static func denialMessage(_ reason: String) -> String {
        switch reason {
        case "timeout": return "Nobody answered the approval prompt in Univocal."
        case "disabled": return "Univocal is set not to allow other apps."
        case "rateLimited": return "Too many approval requests; try again in a minute."
        default: return "Univocal did not allow this app."
        }
    }
}

// MARK: - Per-connection state (actor-confined)

private final class Link {
    let id: Int
    let transport: any UnivocalTransport
    var info: UnivocalServerInfo?
    var maxFrameBytes = UnivocalWire.minimumMaxFrameBytes
    var handshake: CheckedContinuation<UnivocalServerInfo, Error>?
    var pending: [Int: CheckedContinuation<JSONObject, Error>] = [:]
    var sessions: [String: SessionSink] = [:]
    var readerTask: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?
    var fatalError: UnivocalError?
    var tornDown = false

    init(id: Int, transport: any UnivocalTransport) {
        self.id = id
        self.transport = transport
    }
}

// MARK: - State broadcasting

/// Multi-observer fan-out for `stateUpdates()`; registration is synchronous so
/// each new stream yields the current state first.
final class StateBroadcaster: Sendable {
    private struct Box: Sendable {
        var current: UnivocalConnectionState = .disconnected
        var observers: [UUID: AsyncStream<UnivocalConnectionState>.Continuation] = [:]
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    func makeStream() -> AsyncStream<UnivocalConnectionState> {
        let (stream, cont) = AsyncStream<UnivocalConnectionState>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        cont.onTermination = { [weak self] _ in
            _ = self?.box.withLock { $0.observers.removeValue(forKey: id) }
        }
        box.withLock { b in
            cont.yield(b.current)
            b.observers[id] = cont
        }
        return stream
    }

    func set(_ new: UnivocalConnectionState) {
        box.withLock { b in
            b.current = new
            for c in b.observers.values { c.yield(new) }
        }
    }
}

// MARK: - Chunking

/// Splits long text into pieces whose concatenation is exactly the input (SPEC §8):
/// each piece is at most `maxUTF8` bytes and is cut, by preference, right after the
/// last `\n\n`, else the last `\n`, else the last space, else at a scalar boundary.
enum TextChunker {
    static func chunks(_ text: String, maxUTF8: Int) -> [String] {
        let budget = max(4, maxUTF8)
        guard text.utf8.count > budget else { return [text] }
        var out: [String] = []
        var rest = Substring(text)
        while rest.utf8.count > budget {
            let cut = cutIndex(in: rest, maxUTF8: budget)
            out.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }

    private static func cutIndex(in s: Substring, maxUTF8: Int) -> Substring.Index {
        var limit = s.utf8.index(s.startIndex, offsetBy: maxUTF8)
        while limit > s.startIndex, limit < s.endIndex, s.utf8[limit] & 0xC0 == 0x80 {   // UTF-8 continuation byte
            limit = s.utf8.index(before: limit)
        }
        let window = s[s.startIndex..<limit]
        for separator in ["\n\n", "\n", " "] {
            if let r = window.range(of: separator, options: [.backwards, .literal]), r.upperBound > s.startIndex {
                return r.upperBound
            }
        }
        if limit == s.startIndex {
            // A single scalar longer than the budget cannot happen (max 4 bytes); be safe anyway.
            return s.unicodeScalars.index(after: s.startIndex)
        }
        return limit
    }
}
