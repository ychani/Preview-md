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
    private nonisolated let requestBroadcaster = RequestBroadcaster()
    private var link: Link?
    private var nextLinkId = 1
    private var nextRequestId = 1
    private var connectTask: Task<UnivocalServerInfo, Error>?
    /// Set on `unauthorized{revoked}`: connect() refuses to re-prompt until then (SPEC §5.3).
    private var revokedUntil: Date?
    /// Token writes and deletes, chained so they land in order; never awaited
    /// on the handshake path (a Keychain write can sit behind a prompt too).
    private var tokenWrites: Task<Void, Never>?

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
        try await connect(launchIfNeeded: launchIfNeeded, options: HelloOptions())
    }

    private func connect(launchIfNeeded: Bool, options: HelloOptions) async throws -> UnivocalServerInfo {
        var awaited: Task<UnivocalServerInfo, Error>?
        while true {
            if case .connected(let info) = state, let link, !link.tornDown { return info }
            guard let task = connectTask, task != awaited else { break }
            awaited = task
            do {
                return try await task.value
            } catch let e as UnivocalError where e.code == .consentDenied && e.reason == "quiet" && !options.quiet {
                continue   // a quiet connect-at-launch was refused; this caller may prompt
            }
        }
        if let until = revokedUntil {
            if Date() < until {
                throw UnivocalError(code: .unauthorized,
                                    message: "Univocal revoked this app's access. Try again later.",
                                    fatal: true, reason: "revoked")
            }
            revokedUntil = nil
        }
        let task = Task { try await self.performConnect(launchIfNeeded: launchIfNeeded, options: options) }
        connectTask = task
        defer { if connectTask == task { connectTask = nil } }
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
        await tokenWrites?.value
        try await configuration.tokenStore.setToken(nil, forServer: configuration.tokenAccount)
        log("token forgotten")
    }

    // MARK: Token storage, off the critical path

    /// The stored token, or nil after `tokenReadTimeout`: a Keychain read can
    /// wait on a macOS prompt, and the handshake must not. The read keeps
    /// running in the background; its late result is dropped.
    private func storedToken() async -> String? {
        let store = configuration.tokenStore
        let account = configuration.tokenAccount
        let timeout = configuration.tokenReadTimeout
        let started = ContinuousClock.now
        // Unstructured on purpose: a blocked Keychain call ignores
        // cancellation, and a task group would wait for it before returning.
        let read = Task.detached { () -> String? in try? await store.token(forServer: account) }
        let result: String?? = await withCheckedContinuation { cont in
            let once = ResumeOnce()
            Task.detached {
                let token = await read.value
                if once.claim() { cont.resume(returning: .some(token)) }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if once.claim() { cont.resume(returning: .none) }
            }
        }
        switch result {
        case .none:
            log("token store read timed out after \(timeout); hello without a token")
            return nil
        case .some(let token):
            log("token store read \(token == nil ? "empty" : "ok") in \(ContinuousClock.now - started)")
            return token
        }
    }

    /// Saves (or with nil, deletes) the token without blocking the caller.
    private func persistToken(_ token: String?) {
        let store = configuration.tokenStore
        let account = configuration.tokenAccount
        let previous = tokenWrites
        let logger = configuration.logger
        tokenWrites = Task.detached {
            await previous?.value
            do {
                try await store.setToken(token, forServer: account)
            } catch {
                logger?("token store \(token == nil ? "delete" : "write") failed")
            }
        }
    }

    // MARK: Sessions

    /// Starts a reading session. Connects first if needed (same rules as `connect()`).
    /// Returns after the server's `ok` (and after every chunk of a long text was accepted);
    /// the first event is `.state(.loading)`.
    public func read(_ request: ReadRequest) async throws -> ReadingSession {
        let info = try await connect()
        guard let link, !link.tornDown else { throw UnivocalError.disconnected() }
        try validate(request, info: info, link: link)
        return try await startSession(request, info: info, link: link, answering: nil)
    }

    private func validate(_ request: ReadRequest, info: UnivocalServerInfo, link: Link) throws {
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
    }

    /// Sends `read` (+ `append`s) for an already validated request. `answering` adds
    /// `requestId` to the first chunk (SPEC §5.4).
    private func startSession(_ request: ReadRequest, info: UnivocalServerInfo, link: Link,
                              answering requestId: String?) async throws -> ReadingSession {
        let sid = request.sessionId
        let utf16Count = request.text.utf16.count
        let utf8Count = request.text.utf8.count
        let budget = max(1024, min(Self.chunkUTF8Bytes, info.maxFrameBytes / 2))
        var pieces = TextChunker.chunks(request.text, maxUTF8: budget)
        let session = ReadingSession(id: sid, textUTF16Count: utf16Count, client: self)
        link.sessions[sid] = session.sink
        log("read session=\(sid) utf16=\(utf16Count) utf8=\(utf8Count) chunks=\(pieces.count)\(requestId.map { " request=\($0)" } ?? "")")

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
                    if let requestId { msg["requestId"] = .string(requestId) }
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

    // MARK: Hotkey routing (SPEC §5.11, §16)

    /// Hotkey requests from the server (only ever yields when `configuration.hotkeyTarget`
    /// and the server announced `hotkey-routing`). Each call returns an independent stream;
    /// every request is delivered to every live stream, but a request can be answered once —
    /// use one consumer per app. Streams do not end on disconnect; requests pending at
    /// disconnect are simply never answerable (the server fell back). A request that arrives
    /// while no stream is alive is declined at once (`other`, "noConsumer") so Univocal falls
    /// back without waiting for its deadline.
    public nonisolated func readRequests() -> AsyncStream<UnivocalReadRequest> {
        requestBroadcaster.makeStream()
    }

    /// Sends `readAccepted{requestId}`, extending the server's deadline to `acceptedMs`.
    /// Idempotent; throws `requestAnswered` if `read`/`decline` already went out, and
    /// `disconnected` if the connection that delivered the request is gone.
    public func accept(_ request: UnivocalReadRequest) async throws {
        let link = try hotkeyLink(for: request)
        switch link.hotkeyRequests[request.id] {
        case .pending:
            link.hotkeyRequests[request.id] = .accepted
            try sendUnacknowledged(["type": "readAccepted", "requestId": .string(request.id)], on: link)
            log("readAccepted request=\(request.id) after=\(Self.millis(since: request.receivedAt))ms")
        case .accepted:
            return
        case .answered:
            throw Self.alreadyAnswered(request)
        case nil:
            throw Self.unknownHotkeyRequest(request)
        }
    }

    /// Answers a hotkey request with a `read` carrying its `requestId` (SPEC §5.4). Same
    /// validation and chunking as `read(_:)`; `preempt` is sent as `true` regardless. Does NOT
    /// connect: the request came over the live connection. Throws `unknownRequest` when the
    /// server says the request is dead (too late — no UI, no retry); a request that fails
    /// local validation (empty text, bad `startOffset`) stays unanswered so the caller can
    /// still `decline` it. On success the session is ordinary.
    public func read(_ request: ReadRequest, answering hotkey: UnivocalReadRequest) async throws -> ReadingSession {
        let link = try hotkeyLink(for: hotkey)
        switch link.hotkeyRequests[hotkey.id] {
        case .pending, .accepted: break
        case .answered: throw Self.alreadyAnswered(hotkey)
        case nil: throw Self.unknownHotkeyRequest(hotkey)
        }
        guard let info = link.info else { throw UnivocalError.disconnected() }
        try validate(request, info: info, link: link)
        link.hotkeyRequests[hotkey.id] = .answered
        var req = request
        req.preempt = true   // SPEC §5.4: a hotkey read always takes over
        log("answering request=\(hotkey.id) with read session=\(req.sessionId) after=\(Self.millis(since: hotkey.receivedAt))ms")
        do {
            return try await startSession(req, info: info, link: link, answering: hotkey.id)
        } catch let e as UnivocalError where e.code == .unknownRequest {
            log("request=\(hotkey.id) was no longer pending at the server (too late)")
            throw e
        }
    }

    /// Sends `readDecline{requestId, reason, detail?}`; Univocal then runs its own fallback
    /// (or, for `notFocused`, asks another connection of the same app). Allowed after
    /// `accept`. Throws `requestAnswered` on a second answer. `detail` is for logs: a short,
    /// user-neutral word such as "editView" — never document text.
    public func decline(_ request: UnivocalReadRequest, reason: UnivocalDeclineReason, detail: String? = nil) async throws {
        let link = try hotkeyLink(for: request)
        switch link.hotkeyRequests[request.id] {
        case .pending, .accepted: break
        case .answered: throw Self.alreadyAnswered(request)
        case nil: throw Self.unknownHotkeyRequest(request)
        }
        link.hotkeyRequests[request.id] = .answered
        var msg: JSONObject = ["type": "readDecline", "requestId": .string(request.id), "reason": .string(reason.rawValue)]
        if let detail { msg["detail"] = .string(detail) }
        try sendUnacknowledged(msg, on: link)
        log("readDecline request=\(request.id) reason=\(reason.rawValue) after=\(Self.millis(since: request.receivedAt))ms")
    }

    /// SPEC §16.9 connect-at-launch: connects with `hello{quiet:true}` only if a stored token
    /// exists AND the discovery file shows a live server. Never launches Univocal, never
    /// causes a consent prompt. Returns `nil` (no throw) when there is no token, the server
    /// is not running, or the server refused the quiet hello (`consentDenied{reason:"quiet"}`
    /// — the stored token is then deleted — or any other denial / `unauthorized`). Throws
    /// only on transport or protocol failures. Idempotent when already connected.
    public func connectIfAuthorized() async throws -> UnivocalServerInfo? {
        if case .connected(let info) = state, let link, !link.tornDown { return info }
        if let until = revokedUntil, Date() < until {
            log("connect-at-launch skipped: revoked recently")
            return nil
        }
        let token = await storedToken()
        guard token != nil else {
            log("connect-at-launch skipped: no stored token")
            return nil
        }
        guard UnivocalLocator.discovery(in: configuration.connectDirectory) != nil else {
            log("connect-at-launch skipped: server not running")
            return nil
        }
        do {
            return try await connect(launchIfNeeded: false, options: HelloOptions(quiet: true))
        } catch let e as UnivocalError where [.consentDenied, .unauthorized, .notRunning, .notInstalled].contains(e.code) {
            if e.code == .consentDenied, e.reason == "quiet", lastError == e { lastError = nil }
            log("connect-at-launch declined code=\(e.code.rawValue) reason=\(e.reason ?? "-")")
            return nil
        }
    }

    /// SPEC §16.5: the app received a wake URL (`UnivocalWakeURL.parse`). Connects WITHOUT
    /// launching (the server is running — it just woke us) and sends
    /// `hello{wakeRequestId: requestId}`; not quiet: consent may be prompted (the user pressed
    /// the key). If already connected (or connecting), returns that connection's info and
    /// sends nothing: Univocal then times the wake out and falls back. The matching
    /// `readRequest` arrives on `readRequests()` right after `welcome`.
    public func connectForWake(requestId: String) async throws -> UnivocalServerInfo {
        log("wake request=\(requestId)")
        return try await connect(launchIfNeeded: false, options: HelloOptions(wakeRequestId: requestId))
    }

    private func hotkeyLink(for request: UnivocalReadRequest) throws -> Link {
        guard request.linkId != 0, let link, link.id == request.linkId, !link.tornDown else {
            throw UnivocalError.disconnected("The connection that delivered this hotkey request has closed.")
        }
        return link
    }

    private func handleReadRequest(_ msg: JSONObject, link: Link) {
        guard configuration.hotkeyTarget, link.info?.capabilities.contains(Self.hotkeyRoutingCapability) == true else {
            log("ignoring readRequest: hotkey routing was not negotiated")
            return
        }
        guard let req = UnivocalReadRequest(wire: msg, linkId: link.id, receivedAt: ContinuousClock.now) else {
            log("ignoring readRequest with an unknown trigger or no requestId")
            return
        }
        guard link.hotkeyRequests[req.id] == nil else {
            log("ignoring duplicate readRequest request=\(req.id)")
            return
        }
        link.hotkeyRequests[req.id] = .pending
        log("readRequest request=\(req.id) prefer=\(req.prefer.rawValue) answerMs=\(req.answerMs) acceptedMs=\(req.acceptedMs)")
        if requestBroadcaster.broadcast(req) == 0 {
            link.hotkeyRequests[req.id] = .answered
            try? sendUnacknowledged(["type": "readDecline", "requestId": .string(req.id), "reason": "other", "detail": "noConsumer"], on: link)
            log("readDecline request=\(req.id) reason=other (no readRequests() consumer)")
        }
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

    private func performConnect(launchIfNeeded: Bool, options: HelloOptions) async throws -> UnivocalServerInfo {
        do {
            return try await establish(launchIfNeeded: launchIfNeeded, options: options)
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

    private func establish(launchIfNeeded: Bool, options: HelloOptions) async throws -> UnivocalServerInfo {
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
        return try await handshake(over: transport, options: options)
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

    private func handshake(over transport: any UnivocalTransport, options: HelloOptions) async throws -> UnivocalServerInfo {
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

        let token = await storedToken()
        guard self.link === link, !link.tornDown else { throw UnivocalError.disconnected() }

        let c = configuration.client
        var client: JSONObject = ["id": .string(c.id), "name": .string(c.name), "version": .string(c.version)]
        if let b = c.bundleId { client["bundleId"] = .string(b) }
        var capabilities = configuration.clientCapabilities
        if configuration.hotkeyTarget { capabilities.insert(Self.hotkeyTargetCapability) }
        var hello: JSONObject = [
            "type": "hello",
            "protocol": .string(UnivocalWire.protocolName),
            "versions": .array(UnivocalWire.protocolVersions.map { .int($0) }),
            "client": .object(client),
            "capabilities": .array(capabilities.sorted().map { .string($0) }),
        ]
        if let token { hello["token"] = .string(token) }
        if options.quiet { hello["quiet"] = true }
        if let wake = options.wakeRequestId { hello["wakeRequestId"] = .string(wake) }
        let frame = try encodeFrame(hello, limit: UnivocalWire.minimumMaxFrameBytes)
        log("hello client=\(c.id) token=\(token == nil ? "absent" : "present") quiet=\(options.quiet) hotkeyTarget=\(configuration.hotkeyTarget)\(options.wakeRequestId.map { " wakeRequest=\($0)" } ?? "")")

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
                persistToken(token)
            }
        case "consentDenied":
            let reason = msg.string("reason") ?? "user"
            log("consent denied reason=\(reason)")
            if reason == "quiet" {
                // SPEC §5.3: the presented token is no longer valid; never retry without a user action.
                persistToken(nil)
            }
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
        case "readRequest":
            handleReadRequest(msg, link: link)
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
            persistToken(nil)
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

    /// Messages the server never acknowledges (`readAccepted`, `readDecline`).
    private func sendUnacknowledged(_ message: JSONObject, on link: Link) throws {
        guard !link.tornDown else { throw link.fatalError ?? UnivocalError.disconnected() }
        link.transport.send(frame: try encodeFrame(message, limit: link.maxFrameBytes))
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
        if !link.hotkeyRequests.isEmpty {
            log("dropping \(link.hotkeyRequests.values.filter { $0 != .answered }.count) unanswered hotkey request(s)")
            link.hotkeyRequests.removeAll()
        }
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

    static let hotkeyTargetCapability = "hotkey-target"
    static let hotkeyRoutingCapability = "hotkey-routing"

    private static func millis(since instant: ContinuousClock.Instant) -> Int {
        let c = (ContinuousClock.now - instant).components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }

    private static func alreadyAnswered(_ r: UnivocalReadRequest) -> UnivocalError {
        UnivocalError(code: .requestAnswered, message: "Hotkey request \(r.id) was already answered.")
    }

    private static func unknownHotkeyRequest(_ r: UnivocalReadRequest) -> UnivocalError {
        UnivocalError(code: .unknownRequest, message: "Hotkey request \(r.id) did not arrive on this connection.")
    }

    private static func denialMessage(_ reason: String) -> String {
        switch reason {
        case "timeout": return "Nobody answered the approval prompt in Univocal."
        case "disabled": return "Univocal is set not to allow other apps."
        case "rateLimited": return "Too many approval requests; try again in a minute."
        case "quiet": return "Univocal no longer recognises this app's approval."
        default: return "Univocal did not allow this app."
        }
    }
}

/// Extra `hello` fields for Draft 2 (SPEC §5.1).
private struct HelloOptions: Sendable {
    /// `hello.quiet`: connect only if already authorised (§16.9).
    var quiet = false
    /// `hello.wakeRequestId`: answering a wake URL (§16.5).
    var wakeRequestId: String?
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
    /// Hotkey requests this connection delivered, by `requestId` (SPEC §5.11).
    var hotkeyRequests: [String: HotkeyRequestState] = [:]

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

/// Lets exactly one of several racers resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
