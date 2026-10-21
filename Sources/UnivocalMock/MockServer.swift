// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import CryptoKit
import Foundation
import Security
import UnivocalClient

// MARK: - Behaviour

/// How the mock server behaves. Defaults model a cooperative Univocal.
public struct MockBehaviour: Sendable {
    public enum Consent: Sendable {
        /// Grant every consent request immediately (after `consentPending`).
        case autoGrant
        /// Deny every request with `reason` ("user", "disabled", …).
        case autoDeny(reason: String)
        /// Grant after a delay.
        case grantAfter(Duration)
        /// Never answer; after `consentTimeout` deny with `reason: "timeout"`.
        /// `grantPending()` / `denyPending()` still resolve requests (manual tests).
        case timeout
        /// Print a prompt and wait for `grantPending()` / `denyPending()` — the
        /// `univocal-mock serve --consent prompt` CLI wires those to stdin `y`/`n`.
        /// Times out like `.timeout`.
        case askOnStdin
    }

    public var consent: Consent = .autoGrant
    /// Fake clock speed. `<= 0` selects a manual clock: words advance only on `MockServer.advance(words:)`.
    public var wordsPerMinute: Double = 180
    public var loadingDelay: Duration = .milliseconds(300)
    /// token → identity; pre-seeded grants.
    public var knownTokens: [String: String] = [:]
    public var capabilities: Set<String> = ["word-events", "sentence-events", "progress", "seek", "rate", "chunking", "voices", "panel"]
    public var maxFrameBytes = 1_048_576
    public var maxTextBytes = 8_388_608
    /// Sends `{"type":"x-mock-noise"}` after `welcome` and between words, and adds
    /// unknown fields to events (exercises CONFORMANCE C3).
    public var injectUnknownMessages = false
    /// Unsent-outbound-buffer thresholds (SPEC §8): coalesce above the first, close above the second.
    public var slowConsumerThresholds = (coalesce: 262_144, close: 4_194_304)
    /// Logs every outbound session event (offsets only, never text).
    public var verbose = false

    // Additions beyond the plan's sketch:
    public var consentTimeout: Duration = .seconds(120)
    public var rateRange: ClosedRange<Double> = 0.25...4.0
    public var serverName = "Univocal Mock"
    public var serverVersion = "1.0.0"
    public var serverBundleId = "com.univocal.app"
    /// Receives every log line (and consent prompts). Default: stderr when `verbose`, else nothing.
    public var logHandler: (@Sendable (String) -> Void)?

    public init() {}
}

// MARK: - Public façade

/// A conformant Univocal Connect v1 server for tests and manual QA (POSIX Unix
/// socket listener; see `Sources/UnivocalClient/README.md`). Never touches the real
/// `~/Library/Application Support/Univocal*` unless you pass that directory.
public actor MockServer {
    private let engine: MockEngine

    public init(directory: URL, behaviour: MockBehaviour = .init()) {
        engine = MockEngine(directory: directory, behaviour: behaviour)
    }

    /// Creates the directory (0700), socket (0600) and `connect.json`; unlinks a stale socket.
    public func start() async throws { try engine.sync { try $0.start() } }

    /// Closes all connections and removes `connect.json` and the socket.
    public func stop() async { engine.sync { $0.stop() } }

    public var socketPath: String { engine.sync { $0.socketPath } }
    public var directory: URL { engine.directory }
    public var discoveryFileURL: URL { UnivocalPaths.discoveryFileURL(in: engine.directory) }

    // MARK: Test hooks

    /// Grants every pending consent request.
    public func grantPending() async { engine.sync { $0.resolveAllPending(grant: true, reason: nil) } }
    /// Denies every pending consent request (`reason: "user"`).
    public func denyPending() async { engine.sync { $0.resolveAllPending(grant: false, reason: "user") } }
    public var pendingConsentCount: Int { engine.sync { $0.consentQueue.count } }

    /// SPEC §6.1 revocation: ends that identity's session with `ended{revoked}` and
    /// closes its connections with `unauthorized{revoked}`. `"*"` revokes everyone.
    public func revoke(identity: String) async { engine.sync { $0.revoke(identity: identity) } }

    /// Univocal's own reading preempts the active session: `ended{preempted, by:"Univocal"}`.
    public func preemptFromUnivocal() async { engine.sync { $0.preemptFromUnivocal() } }

    /// Manual clock (`wordsPerMinute <= 0`): speaks up to `words` word events of the active
    /// session; once nothing is left, the next step ends it with `finished`.
    public func advance(words: Int = 1) async { engine.sync { $0.active?.advance(words) } }

    public var issuedTokens: [String] { engine.sync { $0.issuedTokens } }
    /// `client.id` of the active session's owner, if any.
    public var activeSessionOwner: String? { engine.sync { $0.activeOwnerClientId } }
    public var activeSessionId: String? { engine.sync { $0.active?.sessionId } }
    public var connectionCount: Int { engine.sync { $0.connections.count } }
    /// `word`/`sentence`/`progress` events dropped by outbound coalescing, all connections.
    public var coalescedEventCount: Int { engine.sync { $0.coalescedTotal } }
    /// Lengths/ids only — tests assert it never contains text.
    public var log: [String] { engine.sync { $0.logLines } }

    /// Console commands for the CLI: `y`/`n`, `preempt`, `revoke <identity>|all`, `status`, `help`.
    public func handleConsoleCommand(_ line: String) async -> String {
        engine.sync { $0.console(line) }
    }
}

// MARK: - Engine (confined to `queue`)

final class MockEngine: @unchecked Sendable {
    struct Grant {
        var clientId: String
        var identity: String
        var name: String
        var createdAt: Date
        var lastUsedAt: Date
    }

    struct PendingConsent {
        var connectionId: Int
        var requestId: String
    }

    let queue = DispatchQueue(label: "com.univocal.mock.engine")
    private let queueKey = DispatchSpecificKey<Bool>()
    let directory: URL
    let behaviour: MockBehaviour

    private(set) var socketPath = ""
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var fallbackDirectory: String?
    private var running = false

    var connections: [Int: MockConnection] = [:]
    private var nextConnectionId = 1
    var active: MockReading?
    /// SHA-256(token) hex → grant. Plaintext tokens are never stored here (SPEC §6.1).
    private var grants: [String: Grant] = [:]
    private var revokedAt: [String: Date] = [:]
    var consentQueue: [PendingConsent] = []
    private var consentHistory: [String: [Date]] = [:]
    /// Test hook only: the plaintexts handed out in `consentGranted`.
    private(set) var issuedTokens: [String] = []
    private(set) var logLines: [String] = []
    private(set) var coalescedTotal = 0

    init(directory: URL, behaviour: MockBehaviour) {
        self.directory = directory.standardizedFileURL
        self.behaviour = behaviour
        queue.setSpecific(key: queueKey, value: true)
        for (token, identity) in behaviour.knownTokens {
            let clientId = identity.split(separator: ":", maxSplits: 1).last.map(String.init) ?? identity
            grants[Self.hash(token)] = Grant(clientId: clientId, identity: identity, name: clientId,
                                             createdAt: Date(), lastUsedAt: Date())
        }
    }

    func sync<T>(_ body: (MockEngine) throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body(self) }
        return try queue.sync { try body(self) }
    }

    var activeOwnerClientId: String? {
        guard let a = active else { return nil }
        return connections[a.ownerId]?.clientId
    }

    // MARK: Logging

    func log(_ line: String) {
        logLines.append(line)
        if let h = behaviour.logHandler {
            h(line)
        } else if behaviour.verbose {
            FileHandle.standardError.write(Data(("univocal-mock: " + line + "\n").utf8))
        }
    }

    // MARK: Start / stop

    func start() throws {
        guard !running else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)

        var path = UnivocalPaths.wellKnownSocketPath(in: directory)
        if !UnivocalPaths.socketPathFits(path) {
            // SPEC §3.1: bind under a 0700 directory we own and advertise the real path.
            var template = Array("/tmp/ucm-XXXXXX".utf8CString)
            guard let p = mkdtemp(&template) else { throw MockError.posix("mkdtemp", errno) }
            let dir = String(cString: p)
            chmod(dir, 0o700)
            fallbackDirectory = dir
            path = dir + "/" + UnivocalPaths.socketFileName
        }
        unlink(path)   // stale socket

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MockError.posix("socket", errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let e = errno
            Darwin.close(fd)
            throw MockError.posix("bind", e)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw MockError.posix("listen", e)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        socketPath = path

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptConnections() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        acceptSource = src

        try writeDiscovery()
        running = true
        log("listening socket=\(path) wpm=\(behaviour.wordsPerMinute) consent=\(consentDescription)")
    }

    func stop() {
        guard running else { return }
        running = false
        if let a = active { a.finish("stopped", silently: true) }
        active = nil
        for conn in Array(connections.values) { closeConnection(conn) }
        consentQueue.removeAll()
        acceptSource?.cancel()
        acceptSource = nil
        unlink(socketPath)
        try? FileManager.default.removeItem(at: UnivocalPaths.discoveryFileURL(in: directory))
        if let dir = fallbackDirectory { rmdir(dir) }
        log("stopped")
    }

    private func writeDiscovery() throws {
        let d = UnivocalDiscovery(socketPath: socketPath, pid: getpid(), serverName: behaviour.serverName,
                                  serverVersion: behaviour.serverVersion, serverBundleId: behaviour.serverBundleId)
        let encoded = try JSONEncoder().encode(d)
        guard var obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }
        obj["startedAt"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let final = UnivocalPaths.discoveryFileURL(in: directory)
        let tmp = directory.appendingPathComponent(".connect.json.\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw MockError.posix("write connect.json", errno)
        }
        chmod(tmp.path, 0o600)
        guard rename(tmp.path, final.path) == 0 else { throw MockError.posix("rename connect.json", errno) }
    }

    private var consentDescription: String {
        switch behaviour.consent {
        case .autoGrant: return "auto"
        case .autoDeny(let r): return "deny:\(r)"
        case .grantAfter(let d): return "after:\(d.timeInterval)s"
        case .timeout: return "timeout"
        case .askOnStdin: return "prompt"
        }
    }

    // MARK: Accept

    private func acceptConnections() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                log("rejected peer with foreign uid")
                Darwin.close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let conn = MockConnection(id: nextConnectionId, fd: fd, maxFrameBytes: behaviour.maxFrameBytes)
            nextConnectionId += 1
            connections[conn.id] = conn

            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            read.setEventHandler { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.readable(conn)
            }
            read.setCancelHandler { [conn] in conn.sourceCancelled() }
            let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            write.setEventHandler { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.flush(conn)
            }
            write.setCancelHandler { [conn] in conn.sourceCancelled() }
            conn.readSource = read
            conn.writeSource = write
            read.resume()
            log("conn#\(conn.id) accepted")
        }
    }

    // MARK: Inbound

    private func readable(_ conn: MockConnection) {
        guard !conn.closed else { return }
        var buf = [UInt8](repeating: 0, count: 65_536)
        while !conn.closed, !conn.closing {
            let n = buf.withUnsafeMutableBytes { Darwin.read(conn.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let frames: [Data]
                do {
                    frames = try conn.framer.push(Data(buf[0..<n]))
                } catch {
                    fatal(conn, code: "protocolError", message: "Frame exceeds \(behaviour.maxFrameBytes) bytes.")
                    return
                }
                for f in frames {
                    guard !conn.closed, !conn.closing else { return }
                    handleFrame(conn, f)
                }
            } else if n == 0 {
                log("conn#\(conn.id) peer closed")
                closeConnection(conn)
                return
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                closeConnection(conn)
                return
            }
        }
    }

    private func handleFrame(_ conn: MockConnection, _ data: Data) {
        let msg: JSONObject
        do {
            msg = try UnivocalWire.decode(data)
        } catch {
            fatal(conn, code: "protocolError", message: "Malformed JSON (\(data.count) bytes).")
            return
        }
        guard let type = msg.messageType else {
            fatal(conn, code: "protocolError", message: "Message without a string `type`.")
            return
        }
        if behaviour.verbose { log("conn#\(conn.id) <- \(type)\(Self.describe(msg))") }
        switch conn.phase {
        case .awaitingHello:
            guard type == "hello" else {
                fatal(conn, code: "protocolError", message: "The first message must be hello.")
                return
            }
            handleHello(conn, msg)
        case .consentPending:
            switch type {
            case "ping": pong(conn, msg)
            case "pong": break
            case "hello": fatal(conn, code: "protocolError", message: "hello was already sent on this connection.")
            default: fatal(conn, code: "unauthorized", message: "Consent is still pending.", extra: ["reason": "pending"])
            }
        case .ready:
            route(conn, type: type, msg: msg)
        }
    }

    private func route(_ conn: MockConnection, type: String, msg: JSONObject) {
        switch type {
        case "hello": fatal(conn, code: "protocolError", message: "hello was already sent on this connection.")
        case "ping": pong(conn, msg)
        case "pong": break
        case "listVoices" where behaviour.capabilities.contains("voices"):
            var reply: JSONObject = [
                "type": "voices", "default": "mock_alice",
                "voices": [
                    ["id": "mock_alice", "name": "Alice (mock)", "lang": "en-US"],
                    ["id": "mock_bob", "name": "Bob (mock)", "lang": "en-GB"],
                ],
            ]
            if let id = msg["id"] { reply["id"] = id }
            send(conn, reply)
        case "read": handleRead(conn, msg)
        case "append": handleAppend(conn, msg)
        case "pause", "resume", "stop", "seek", "setRate": handleControl(conn, type: type, msg: msg)
        default:
            if let id = msg["id"] {
                sendError(conn, code: "unknownType", message: "Unknown message type.", id: id)
            }
        }
    }

    // MARK: Hello & consent

    private func handleHello(_ conn: MockConnection, _ msg: JSONObject) {
        guard msg.string("protocol") == UnivocalWire.protocolName else {
            fatal(conn, code: "protocolError", message: "Unknown protocol; expected univocal-connect.")
            return
        }
        let versions = (msg.array("versions") ?? []).compactMap(\.intValue)
        guard versions.contains(where: UnivocalWire.protocolVersions.contains) else {
            fatal(conn, code: "unsupportedVersion", message: "No common protocol version.",
                  extra: ["versions": .array(UnivocalWire.protocolVersions.map { .int($0) })])
            return
        }
        guard let client = msg.object("client"), let cid = client.string("id"),
              UnivocalClientIdentity.isValidClientId(cid) else {
            fatal(conn, code: "invalidArgument", message: "client.id must match [A-Za-z0-9._-]{1,128}.", extra: ["field": "client.id"])
            return
        }
        guard let name = client.string("name"), !name.isEmpty else {
            fatal(conn, code: "invalidArgument", message: "client.name is required.", extra: ["field": "client.name"])
            return
        }
        guard client.string("version") != nil else {
            fatal(conn, code: "invalidArgument", message: "client.version is required.", extra: ["field": "client.version"])
            return
        }
        conn.clientId = cid
        conn.clientName = String(name.prefix(64))
        conn.identity = "unverified:\(cid)"
        conn.capabilities = Set((msg.array("capabilities") ?? []).compactMap(\.stringValue))
        let token = msg.string("token")
        log("conn#\(conn.id) hello client=\(cid) identity=\(conn.identity) token=\(token == nil ? "absent" : "present") caps=\(conn.capabilities.sorted().joined(separator: ","))")

        if let token {
            let h = Self.hash(token)
            if var g = grants[h] {
                if g.clientId == cid, g.identity == conn.identity {
                    g.lastUsedAt = Date()
                    grants[h] = g
                    welcome(conn)
                    return
                }
                log("conn#\(conn.id) token bound to another identity; re-prompting")
            } else if let t = revokedAt[h], Date().timeIntervalSince(t) < 600 {
                fatal(conn, code: "unauthorized", message: "Access was revoked.", extra: ["reason": "revoked"])
                return
            }
        }
        beginConsent(conn)
    }

    private func beginConsent(_ conn: MockConnection) {
        let now = Date()
        var history = consentHistory[conn.identity, default: []].filter { now.timeIntervalSince($0) < 60 }
        let requestId = Self.shortId()
        guard history.count < 3 else {
            consentHistory[conn.identity] = history
            log("conn#\(conn.id) consent rate-limited identity=\(conn.identity)")
            send(conn, ["type": "consentDenied", "requestId": .string(requestId), "reason": "rateLimited"])
            closeAfterFlush(conn)
            return
        }
        history.append(now)
        consentHistory[conn.identity] = history
        conn.phase = .consentPending(requestId)
        let timeout = behaviour.consentTimeout.timeInterval
        send(conn, ["type": "consentPending", "requestId": .string(requestId), "timeoutSeconds": .int(Int(timeout.rounded()))])
        consentQueue.append(PendingConsent(connectionId: conn.id, requestId: requestId))
        log("conn#\(conn.id) consent pending request=\(requestId)")

        switch behaviour.consent {
        case .autoGrant:
            queue.async { [weak self] in self?.resolveConsent(requestId, grant: true, reason: nil) }
        case .autoDeny(let reason):
            queue.async { [weak self] in self?.resolveConsent(requestId, grant: false, reason: reason) }
        case .grantAfter(let d):
            queue.asyncAfter(deadline: .now() + d.timeInterval) { [weak self] in self?.resolveConsent(requestId, grant: true, reason: nil) }
        case .timeout, .askOnStdin:
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resolveConsent(requestId, grant: false, reason: "timeout") }
            if case .askOnStdin = behaviour.consent, consentQueue.count == 1 { promptHead() }
        }
    }

    private func promptHead() {
        guard let head = consentQueue.first, let conn = connections[head.connectionId] else { return }
        log("[consent] \(conn.clientName) (\(conn.identity), unverified build) can send text for Univocal to read aloud and will receive reading progress. Allow? [y/n]")
    }

    func resolveConsent(_ requestId: String, grant: Bool, reason: String?) {
        guard let idx = consentQueue.firstIndex(where: { $0.requestId == requestId }) else { return }
        let p = consentQueue.remove(at: idx)
        defer {
            if case .askOnStdin = behaviour.consent, idx == 0, !consentQueue.isEmpty { promptHead() }
        }
        guard let conn = connections[p.connectionId], !conn.closed, case .consentPending(let rid) = conn.phase, rid == requestId else { return }
        if grant {
            let token = Self.makeToken()
            grants[Self.hash(token)] = Grant(clientId: conn.clientId, identity: conn.identity, name: conn.clientName,
                                             createdAt: Date(), lastUsedAt: Date())
            issuedTokens.append(token)
            log("conn#\(conn.id) consent granted identity=\(conn.identity)")
            send(conn, ["type": "consentGranted", "requestId": .string(requestId), "token": .string(token)])
            welcome(conn)
        } else {
            let r = reason ?? "user"
            log("conn#\(conn.id) consent denied reason=\(r)")
            send(conn, ["type": "consentDenied", "requestId": .string(requestId), "reason": .string(r)])
            closeAfterFlush(conn)
        }
    }

    func resolveAllPending(grant: Bool, reason: String?) {
        for p in consentQueue { resolveConsent(p.requestId, grant: grant, reason: reason) }
    }

    private func welcome(_ conn: MockConnection) {
        conn.phase = .ready
        var msg: JSONObject = [
            "type": "welcome",
            "version": 1,
            "server": ["name": .string(behaviour.serverName), "version": .string(behaviour.serverVersion),
                       "bundleId": .string(behaviour.serverBundleId)],
            "capabilities": .array(behaviour.capabilities.sorted().map { .string($0) }),
            "limits": ["maxFrameBytes": .int(behaviour.maxFrameBytes), "maxTextBytes": .int(behaviour.maxTextBytes),
                       "rate": ["min": .double(behaviour.rateRange.lowerBound), "max": .double(behaviour.rateRange.upperBound)]],
            "grant": ["clientId": .string(conn.clientId), "identity": .string(conn.identity)],
        ]
        if behaviour.injectUnknownMessages { msg["x-mock-extra"] = ["nested": true] }
        send(conn, msg)
        log("conn#\(conn.id) welcome identity=\(conn.identity)")
        if behaviour.injectUnknownMessages {
            send(conn, ["type": "x-mock-noise", "note": "clients must ignore unknown message types"])
        }
    }

    func revoke(identity: String) {
        let now = Date()
        for (h, g) in grants where identity == "*" || g.identity == identity {
            grants[h] = nil
            revokedAt[h] = now
        }
        log("revoked identity=\(identity)")
        for conn in connections.values where !conn.closed && (identity == "*" || conn.identity == identity) {
            if let a = active, a.ownerId == conn.id { a.finish("revoked") }
            if case .ready = conn.phase {
                fatal(conn, code: "unauthorized", message: "Access was revoked in Univocal.", extra: ["reason": "revoked"])
            }
        }
    }

    func preemptFromUnivocal() {
        guard let a = active else { return }
        log("univocal preempts session=\(a.sessionId)")
        a.finish("preempted", by: "Univocal")
    }

    // MARK: Sessions

    private func handleRead(_ conn: MockConnection, _ msg: JSONObject) {
        let id = msg["id"]
        guard let sid = msg.string("sessionId"), !sid.isEmpty else {
            return sendError(conn, code: "invalidArgument", message: "sessionId is required.", id: id, extra: ["field": "sessionId"])
        }
        guard let text = msg.string("text") else {
            return sendError(conn, code: "invalidArgument", message: "text must be a string.", id: id, sessionId: sid, extra: ["field": "text"])
        }
        if let m = msg["more"], m.boolValue == nil {
            return sendError(conn, code: "invalidArgument", message: "more must be a boolean.", id: id, sessionId: sid, extra: ["field": "more"])
        }
        let more = msg.bool("more") ?? false
        if text.isEmpty, !more {
            return sendError(conn, code: "invalidArgument", message: "text is empty.", id: id, sessionId: sid, extra: ["field": "text"])
        }
        if let a = active, a.ownerId == conn.id, a.sessionId == sid {
            return sendError(conn, code: "sessionExists", message: "That sessionId is live on this connection.", id: id, sessionId: sid)
        }
        var rate = 1.0
        if let r = msg["rate"], !r.isNull {
            guard let d = r.doubleValue, d.isFinite, d > 0 else {
                return sendError(conn, code: "invalidArgument", message: "rate must be a positive number.", id: id, sessionId: sid, extra: ["field": "rate"])
            }
            rate = min(max(d, behaviour.rateRange.lowerBound), behaviour.rateRange.upperBound)
        }
        var startOffset = 0
        if let s = msg["startOffset"], !s.isNull {
            guard let i = s.intValue else {
                return sendError(conn, code: "invalidArgument", message: "startOffset must be an integer.", id: id, sessionId: sid, extra: ["field": "startOffset"])
            }
            startOffset = i
        }
        let utf8 = text.utf8.count
        guard utf8 <= behaviour.maxTextBytes else {
            return sendError(conn, code: "limitExceeded", message: "Text exceeds \(behaviour.maxTextBytes) bytes.", id: id, sessionId: sid)
        }
        let utf16 = (text as NSString).length
        if startOffset < 0 || (!more && startOffset > utf16) {
            return sendError(conn, code: "invalidOffset", message: "startOffset \(startOffset) is outside 0…\(utf16).", id: id, sessionId: sid)
        }
        let preempt = msg.bool("preempt") ?? true
        if let a = active {
            guard preempt else {
                return sendError(conn, code: "busy", message: "Univocal is reading something else.", id: id, sessionId: sid)
            }
            log("conn#\(conn.id) preempts session=\(a.sessionId)")
            a.finish("preempted", by: conn.clientName)
        }
        let reading = MockReading(engine: self, sessionId: sid, ownerId: conn.id, rate: rate)
        active = reading
        if let id { send(conn, ["type": "ok", "id": id, "sessionId": .string(sid)]) }
        log("conn#\(conn.id) read session=\(sid) utf16=\(utf16) utf8=\(utf8) more=\(more) startOffset=\(startOffset) preempt=\(preempt) ui=\(msg.string("ui") ?? "none")")
        reading.append(text, more: more)
        reading.start(startOffset: startOffset)
    }

    private func handleAppend(_ conn: MockConnection, _ msg: JSONObject) {
        let id = msg["id"]
        guard let reading = ownedSession(conn, msg, id: id) else { return }
        let sid = reading.sessionId
        guard let text = msg.string("text") else {
            return sendError(conn, code: "invalidArgument", message: "text must be a string.", id: id, sessionId: sid, extra: ["field": "text"])
        }
        guard reading.morePending else {
            return sendError(conn, code: "invalidArgument", message: "The session is not expecting more text.", id: id, sessionId: sid, extra: ["field": "more"])
        }
        let more = msg.bool("more") ?? false
        let total = reading.utf8Bytes + text.utf8.count
        guard total <= behaviour.maxTextBytes else {
            sendError(conn, code: "limitExceeded", message: "Session text exceeds \(behaviour.maxTextBytes) bytes.", id: id, sessionId: sid)
            reading.finish("error")
            return
        }
        if let id { send(conn, ["type": "ok", "id": id, "sessionId": .string(sid)]) }
        log("conn#\(conn.id) append session=\(sid) utf16=\((text as NSString).length) utf8=\(text.utf8.count) more=\(more)")
        reading.append(text, more: more)
    }

    private func handleControl(_ conn: MockConnection, type: String, msg: JSONObject) {
        let id = msg["id"]
        guard let reading = ownedSession(conn, msg, id: id) else { return }
        let sid = reading.sessionId
        func ok() { if let id { send(conn, ["type": "ok", "id": id, "sessionId": .string(sid)]) } }
        switch type {
        case "pause":
            ok()
            reading.pause()
        case "resume":
            ok()
            reading.resume()
        case "stop":
            ok()
            reading.finish("stopped")
        case "seek":
            guard let offset = msg.int("offset") else {
                return sendError(conn, code: "invalidArgument", message: "offset must be an integer.", id: id, sessionId: sid, extra: ["field": "offset"])
            }
            guard offset >= 0, offset <= reading.utf16Length else {
                return sendError(conn, code: "invalidOffset", message: "offset \(offset) exceeds text length \(reading.utf16Length).", id: id, sessionId: sid)
            }
            ok()
            reading.seek(to: offset)
        case "setRate":
            guard let r = msg.double("rate"), r.isFinite, r > 0 else {
                return sendError(conn, code: "invalidArgument", message: "rate must be a positive number.", id: id, sessionId: sid, extra: ["field": "rate"])
            }
            ok()
            reading.setRate(min(max(r, behaviour.rateRange.lowerBound), behaviour.rateRange.upperBound))
        default:
            break
        }
        log("conn#\(conn.id) \(type) session=\(sid)")
    }

    private func ownedSession(_ conn: MockConnection, _ msg: JSONObject, id: JSONValue?) -> MockReading? {
        guard let sid = msg.string("sessionId") else {
            sendError(conn, code: "invalidArgument", message: "sessionId is required.", id: id, extra: ["field": "sessionId"])
            return nil
        }
        guard let a = active, a.sessionId == sid else {
            sendError(conn, code: "noSession", message: "No live session with that id.", id: id, sessionId: sid)
            return nil
        }
        guard a.ownerId == conn.id else {
            sendError(conn, code: "notOwner", message: "This connection does not own that session.", id: id, sessionId: sid)
            return nil
        }
        return a
    }

    /// Session events go to the owner only, gated by the capabilities it asked for (SPEC §11).
    func sessionEvent(_ reading: MockReading, _ event: JSONObject) {
        guard let conn = connections[reading.ownerId], !conn.closed, !conn.closing else { return }
        let type = event.messageType ?? ""
        switch type {
        case "word" where !conn.capabilities.contains("word-events"): return
        case "sentence" where !conn.capabilities.contains("sentence-events"): return
        case "progress" where !(conn.capabilities.contains("progress") && behaviour.capabilities.contains("progress")): return
        default: break
        }
        var msg = event
        msg["sessionId"] = .string(reading.sessionId)
        if behaviour.injectUnknownMessages { msg["x-mock-extra"] = 1 }
        let coalescable = type == "word" || type == "sentence" || type == "progress"
        send(conn, msg, coalesceKey: coalescable ? "\(type)|\(reading.sessionId)" : nil)
        if behaviour.verbose { log("conn#\(conn.id) -> \(type)\(Self.describe(msg))") }
        if behaviour.injectUnknownMessages, type == "word", reading.wordEvents % 3 == 0 {
            send(conn, ["type": "x-mock-noise", "sessionId": .string(reading.sessionId)])
        }
    }

    func readingEnded(_ reading: MockReading, reason: String, by: String?, silently: Bool) {
        if active === reading { active = nil }
        log("session=\(reading.sessionId) ended reason=\(reason) words=\(reading.wordEvents) sentences=\(reading.sentenceEvents) utf16=\(reading.utf16Length)")
        guard !silently, let conn = connections[reading.ownerId], !conn.closed else { return }
        var msg: JSONObject = ["type": "ended", "sessionId": .string(reading.sessionId), "reason": .string(reason)]
        if let by { msg["by"] = .string(by) }
        // `ended{error}` must be preceded by an `error` for the session; callers send it first.
        send(conn, msg)
    }

    // MARK: Errors & small replies

    private func pong(_ conn: MockConnection, _ msg: JSONObject) {
        var reply: JSONObject = ["type": "pong"]
        if let id = msg["id"] { reply["id"] = id }
        send(conn, reply)
    }

    private func sendError(_ conn: MockConnection, code: String, message: String, id: JSONValue? = nil,
                           sessionId: String? = nil, fatal: Bool = false, extra: JSONObject = [:]) {
        var msg: JSONObject = ["type": "error", "code": .string(code), "message": .string(message), "fatal": .bool(fatal)]
        if let id { msg["id"] = id }
        if let sessionId { msg["sessionId"] = .string(sessionId) }
        for (k, v) in extra { msg[k] = v }
        send(conn, msg)
        log("conn#\(conn.id) error code=\(code) fatal=\(fatal)\(sessionId.map { " session=\($0)" } ?? "")")
    }

    private func fatal(_ conn: MockConnection, code: String, message: String, extra: JSONObject = [:]) {
        sendError(conn, code: code, message: message, fatal: true, extra: extra)
        closeAfterFlush(conn)
    }

    private func closeAfterFlush(_ conn: MockConnection) {
        guard !conn.closed, !conn.closing else { return }
        conn.closing = true
        conn.readSource?.cancel()
        conn.readSource = nil
        if let a = active, a.ownerId == conn.id { a.finish("error", silently: true) }
        flush(conn)
        // Do not wait forever for a peer that never reads.
        queue.asyncAfter(deadline: .now() + 1) { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.closeConnection(conn)
        }
    }

    // MARK: Outbound with coalescing (SPEC §8)

    private func send(_ conn: MockConnection, _ msg: JSONObject, coalesceKey: String? = nil) {
        guard !conn.closed, let data = try? UnivocalWire.frame(msg) else { return }
        if let key = coalesceKey, conn.unsentBytes > behaviour.slowConsumerThresholds.coalesce {
            coalescedTotal += conn.dropQueued(key: key)
        }
        conn.enqueue(data, key: coalesceKey)
        if conn.unsentBytes > behaviour.slowConsumerThresholds.close {
            slowConsumer(conn)
            return
        }
        flush(conn)
    }

    private func slowConsumer(_ conn: MockConnection) {
        log("conn#\(conn.id) slow consumer unsent=\(conn.unsentBytes); closing")
        conn.dropAllUnstarted()
        if let data = try? UnivocalWire.frame(["type": "error", "code": "slowConsumer",
                                               "message": "The client is not reading; closing.", "fatal": true]) {
            conn.enqueue(data, key: nil)
        }
        closeAfterFlush(conn)
    }

    fileprivate func flush(_ conn: MockConnection) {
        guard !conn.closed else { return }
        switch conn.writeSome() {
        case .drained:
            conn.setWriteInterest(false)
            if conn.closing { closeConnection(conn) }
        case .wouldBlock:
            conn.setWriteInterest(true)
        case .failed:
            closeConnection(conn)
        }
    }

    func closeConnection(_ conn: MockConnection) {
        guard !conn.closed else { return }
        conn.closed = true
        connections[conn.id] = nil
        if let a = active, a.ownerId == conn.id { a.finish("error", silently: true) }   // owner gone: ends silently
        consentQueue.removeAll { $0.connectionId == conn.id }
        conn.cancelSources()
        log("conn#\(conn.id) closed dropped=\(conn.droppedEvents)")
    }

    // MARK: Console

    func console(_ raw: String) -> String {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first?.lowercased() ?? "" {
        case "y", "yes", "allow", "grant":
            let n = consentQueue.count
            resolveAllPending(grant: true, reason: nil)
            return n == 0 ? "no consent request is pending" : "granted \(n) request(s)"
        case "n", "no", "deny":
            let n = consentQueue.count
            resolveAllPending(grant: false, reason: "user")
            return n == 0 ? "no consent request is pending" : "denied \(n) request(s)"
        case "preempt":
            guard active != nil else { return "no active session" }
            preemptFromUnivocal()
            return "preempted the active session (by: Univocal)"
        case "revoke":
            let who = parts.count > 1 ? parts[1] : "*"
            revoke(identity: who == "all" ? "*" : who)
            return "revoked \(who)"
        case "status":
            let ids = connections.values.sorted { $0.id < $1.id }.map { "conn#\($0.id) \($0.identity.isEmpty ? "(no hello)" : $0.identity)" }
            let session = active.map { "session=\($0.sessionId) owner=conn#\($0.ownerId) paused=\($0.paused)" } ?? "no active session"
            return "connections: \(ids.isEmpty ? "none" : ids.joined(separator: ", ")); \(session); pending consent: \(consentQueue.count); grants: \(grants.count)"
        case "", "help", "?":
            return "commands: y | n (answer consent), preempt, revoke <identity>|all, status, help"
        default:
            return "unknown command \"\(parts.first ?? "")\" — try help"
        }
    }

    // MARK: Helpers

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 32 random bytes, base64url without padding, prefixed `uc1_` (SPEC §6.1).
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        }
        let b64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "uc1_" + b64
    }

    static func shortId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    /// Ids, offsets and lengths only — never text.
    static func describe(_ msg: JSONObject) -> String {
        var parts: [String] = []
        if let id = msg["id"] {
            switch id {
            case .int(let i): parts.append("id=\(i)")
            case .string(let s): parts.append("id=\(s.prefix(24))")
            default: break
            }
        }
        if let s = msg.string("sessionId") { parts.append("session=\(s.prefix(40))") }
        if let a = msg.int("start"), let b = msg.int("end") { parts.append("[\(a),\(b))") }
        if let o = msg.int("offset") { parts.append("offset=\(o)") }
        if let s = msg.string("state") { parts.append("state=\(s)") }
        if let r = msg.string("reason") { parts.append("reason=\(r)") }
        if let r = msg.double("rate") { parts.append("rate=\(r)") }
        if let t = msg.string("text") { parts.append("utf16=\((t as NSString).length)") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }
}

enum MockError: Error, CustomStringConvertible {
    case posix(String, Int32)

    var description: String {
        switch self {
        case .posix(let op, let e): return "\(op) failed: \(String(cString: strerror(e)))"
        }
    }
}

// MARK: - Connection (confined to the engine queue)

final class MockConnection: @unchecked Sendable {
    enum Phase: Equatable {
        case awaitingHello
        case consentPending(String)
        case ready
    }

    enum WriteResult { case drained, wouldBlock, failed }

    private struct Frame {
        var data: Data
        var key: String?
    }

    let id: Int
    let fd: Int32
    var framer: NDJSONFramer
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    private var writeInterest = false
    private var liveSources = 2

    var phase: Phase = .awaitingHello
    var closing = false
    var closed = false
    var clientId = ""
    var clientName = ""
    var identity = ""
    var capabilities: Set<String> = []

    // Outbound queue: frames[head...] are unsent; `offset` bytes of frames[head] are written.
    private var frames: [Frame] = []
    /// key → indices into `frames` of queued frames with that coalescing key.
    private var keyIndices: [String: [Int]] = [:]
    private var head = 0
    private var offset = 0
    private(set) var unsentBytes = 0
    private(set) var droppedEvents = 0

    init(id: Int, fd: Int32, maxFrameBytes: Int) {
        self.id = id
        self.fd = fd
        self.framer = NDJSONFramer(maxFrameBytes: maxFrameBytes)
    }

    func enqueue(_ data: Data, key: String?) {
        if let key { keyIndices[key, default: []].append(frames.count) }
        frames.append(Frame(data: data, key: key))
        unsentBytes += data.count
    }

    /// Drops every queued, not-yet-started frame with `key` — all superseded by the
    /// frame about to be enqueued. Returns the count.
    func dropQueued(key: String) -> Int {
        guard let indices = keyIndices[key], !indices.isEmpty else { return 0 }
        let firstDroppable = offset > 0 ? head + 1 : head
        var dropped = 0
        var keep: [Int] = []
        for i in indices where i < frames.count && frames[i].key == key {
            if i >= firstDroppable {
                unsentBytes -= frames[i].data.count
                frames[i] = Frame(data: Data(), key: nil)
                dropped += 1
            } else if i >= head {
                keep.append(i)   // partially written: must go out whole
            }
        }
        keyIndices[key] = keep
        droppedEvents += dropped
        return dropped
    }

    func dropAllUnstarted() {
        let firstDroppable = offset > 0 ? head + 1 : head
        guard firstDroppable < frames.count else { return }
        for i in firstDroppable..<frames.count where !frames[i].data.isEmpty {
            unsentBytes -= frames[i].data.count
            if frames[i].key != nil { droppedEvents += 1 }
        }
        frames.removeSubrange(firstDroppable...)
        keyIndices.removeAll()
    }

    func writeSome() -> WriteResult {
        while head < frames.count {
            let data = frames[head].data
            if data.isEmpty {
                head += 1
                continue
            }
            let remaining = data.count - offset
            let n = data.withUnsafeBytes { p in Darwin.write(fd, p.baseAddress! + offset, remaining) }
            if n > 0 {
                offset += n
                unsentBytes -= n
                if offset == data.count {
                    head += 1
                    offset = 0
                }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                compact()
                return .wouldBlock
            }
            return .failed
        }
        frames.removeAll(keepingCapacity: true)
        keyIndices.removeAll(keepingCapacity: true)
        head = 0
        return .drained
    }

    private func compact() {
        if head > 1024, head * 2 > frames.count {
            let shift = head
            frames.removeFirst(shift)
            head = 0
            for (k, v) in keyIndices { keyIndices[k] = v.compactMap { $0 >= shift ? $0 - shift : nil } }
        }
    }

    /// Resumes/suspends the write source (it is created suspended).
    func setWriteInterest(_ on: Bool) {
        guard let w = writeSource, on != writeInterest else { return }
        writeInterest = on
        if on { w.resume() } else { w.suspend() }
    }

    func cancelSources() {
        if let r = readSource {
            r.cancel()
            readSource = nil
        }
        if let w = writeSource {
            if !writeInterest { w.resume() }   // a suspended source never runs its cancel handler
            writeInterest = true
            w.cancel()
            writeSource = nil
        }
    }

    /// Called from each source's cancel handler; closes the fd once both are gone.
    func sourceCancelled() {
        liveSources -= 1
        if liveSources == 0 { Darwin.close(fd) }
    }
}
