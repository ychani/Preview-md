// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import UnivocalClient
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Public types

/// What `NSWorkspace.shared.frontmostApplication` would report at a hotkey press (SPEC §16.2).
public struct MockFrontmost: Sendable, Equatable, CustomStringConvertible {
    /// `nil` = no process to resolve against (only bundle containment / the wake path can match).
    public var pid: pid_t?
    public var bundleId: String
    /// Containment test (§16.3) and the `Info.plist` read by the wake path (§16.5).
    public var bundleURL: URL?

    public init(pid: pid_t?, bundleId: String, bundleURL: URL? = nil) {
        self.pid = pid
        self.bundleId = bundleId
        self.bundleURL = bundleURL
    }

    public var description: String {
        "\(bundleId) pid=\(pid.map(String.init) ?? "-")\(bundleURL.map { " bundle=\($0.path)" } ?? "")"
    }
}

/// Final outcome of one simulated press (SPEC §16.4: exactly one per press).
public enum MockHotkeyOutcome: Sendable, Equatable, CustomStringConvertible {
    /// The frontmost app is the server itself (§16.11): no routing.
    case selfHandled
    case toggled(sessionId: String, paused: Bool)
    case routed(sessionId: String, clientId: String, requestId: String, accepted: Bool, viaWake: Bool)
    /// `reason`: noTarget | noDeclaration | wakeFailed | wakeTimeout | consentDenied | answerTimeout |
    /// acceptedTimeout | declined:<reason> | readRejected:<code> | superseded | disconnected.
    /// Every reason except `superseded` ran the server's own fallback (panel read).
    case fellBack(reason: String)

    public var description: String {
        switch self {
        case .selfHandled: return "self (Univocal is frontmost; no routing)"
        case .toggled(let sid, let paused): return "toggled \(paused ? "paused" : "playing") session=\(sid)"
        case .routed(let sid, let cid, let rid, let accepted, let viaWake):
            return "routed \(cid) session=\(sid) request=\(rid) accepted=\(accepted) viaWake=\(viaWake)"
        case .fellBack(let reason): return "fell back \(reason)"
        }
    }
}

// MARK: - One press (engine-queue confined)

final class HotkeyPress {
    let number: Int
    let prefer: UnivocalReadRequest.Preference
    let frontmost: MockFrontmost
    let startedAt = DispatchTime.now()
    let completion: @Sendable (MockHotkeyOutcome) -> Void

    /// The live request id (asked, or being woken). Every other id is dead.
    var requestId: String?
    var askedConnId: Int?
    var sentAt: DispatchTime?
    var accepted = false
    var candidates: [Int] = []
    var waking = false
    var wakeConnId: Int?
    var viaWake = false
    var timer: DispatchSourceTimer?
    var done = false

    init(number: Int, prefer: UnivocalReadRequest.Preference, frontmost: MockFrontmost,
         completion: @escaping @Sendable (MockHotkeyOutcome) -> Void) {
        self.number = number
        self.prefer = prefer
        self.frontmost = frontmost
        self.completion = completion
    }
}

// MARK: - SPEC §16.4 on the engine

extension MockEngine {
    func setFrontmost(_ f: MockFrontmost?) {
        frontmost = f
        log("frontmost \(f.map { "\($0)" } ?? "none")")
    }

    func resolves(_ conn: MockConnection, _ f: MockFrontmost) -> Bool {
        guard let pid = conn.peerPid else { return false }
        return ProcessAncestry.resolves(peerPid: pid, appPid: f.pid, appBundleURL: f.bundleURL)
    }

    func startPress(prefer: UnivocalReadRequest.Preference, completion: @escaping @Sendable (MockHotkeyOutcome) -> Void) {
        if let old = press { conclude(old, .fellBack(reason: "superseded")) }   // newest press wins, no fallback for the old one
        let number = nextPressNumber
        nextPressNumber += 1
        // Step 1: capture the frontmost app first.
        let f = frontmost ?? MockFrontmost(pid: nil, bundleId: "(none)")
        let p = HotkeyPress(number: number, prefer: prefer, frontmost: f, completion: completion)
        press = p
        log("hotkey #\(number) pressed frontmost=\(f) prefer=\(prefer.rawValue)")
        if f.bundleId == behaviour.serverBundleId {
            return conclude(p, .selfHandled)
        }
        // Step 2: toggle when the active session's owner resolves to F; otherwise preempt it.
        if let a = active, frontmost != nil, let owner = connections[a.ownerId], resolves(owner, f) {
            if a.paused { a.resume() } else { a.pause() }
            return conclude(p, .toggled(sessionId: a.sessionId, paused: a.paused))
        }
        if let a = active {
            log("hotkey #\(number) preempts session=\(a.sessionId)")
            a.finish("preempted", by: "Univocal")
        }
        guard frontmost != nil, behaviour.hotkeyRouting else { return conclude(p, .fellBack(reason: "noTarget")) }
        // Step 3: candidates, most recent inbound first, then newest connection.
        p.candidates = connections.values
            .filter { c in
                !c.closed && !c.closing && c.phase == .ready && c.capabilities.contains("hotkey-target") && resolves(c, f)
            }
            .sorted { a, b in a.lastInboundAt != b.lastInboundAt ? a.lastInboundAt > b.lastInboundAt : a.id > b.id }
            .map(\.id)
        if p.candidates.isEmpty {
            wake(p)                   // step 4
        } else {
            log("hotkey #\(number) candidates=\(p.candidates.map { "conn#\($0)" }.joined(separator: ","))")
            askNext(p, exhausted: "noTarget")
        }
    }

    /// Step 5 with the next candidate (a fresh `requestId` each time).
    private func askNext(_ p: HotkeyPress, exhausted: String) {
        while !p.candidates.isEmpty {
            let cid = p.candidates.removeFirst()
            guard let conn = connections[cid], !conn.closed, !conn.closing, conn.phase == .ready else { continue }
            return ask(p, conn, requestId: Self.requestId())
        }
        conclude(p, .fellBack(reason: exhausted))
    }

    private func ask(_ p: HotkeyPress, _ conn: MockConnection, requestId rid: String) {
        p.requestId = rid
        p.askedConnId = conn.id
        p.accepted = false
        p.waking = false
        let sent = DispatchTime.now()
        p.sentAt = sent
        send(conn, ["type": "readRequest", "requestId": .string(rid), "trigger": "hotkey",
                    "prefer": .string(p.prefer.rawValue),
                    "answerMs": .int(Self.millis(behaviour.answerDeadline)),
                    "acceptedMs": .int(Self.millis(behaviour.acceptedDeadline))])
        log("hotkey #\(p.number) asking conn#\(conn.id) client=\(conn.clientId) pid=\(conn.peerPid.map(String.init) ?? "?") request=\(rid) answerMs=\(Self.millis(behaviour.answerDeadline)) acceptedMs=\(Self.millis(behaviour.acceptedDeadline))")
        arm(p, deadline: sent + behaviour.answerDeadline.timeInterval)
    }

    // MARK: Answers

    func hotkeyAccepted(_ conn: MockConnection, _ msg: JSONObject) {
        guard let rid = msg.string("requestId"), let p = press, !p.done, !p.waking,
              p.requestId == rid, p.askedConnId == conn.id, let sent = p.sentAt else {
            if behaviour.verbose { log("conn#\(conn.id) stale readAccepted ignored") }
            return
        }
        guard !p.accepted else { return }
        p.accepted = true
        arm(p, deadline: sent + behaviour.acceptedDeadline.timeInterval)
        log("hotkey #\(p.number) accepted by conn#\(conn.id) request=\(rid) after=\(Self.elapsedMs(since: sent))ms")
    }

    func hotkeyDeclined(_ conn: MockConnection, _ msg: JSONObject) {
        guard let rid = msg.string("requestId"), let p = press, !p.done, !p.waking,
              p.requestId == rid, p.askedConnId == conn.id, let sent = p.sentAt else {
            if behaviour.verbose { log("conn#\(conn.id) stale readDecline ignored") }
            return
        }
        let reason = msg.string("reason") ?? "other"
        log("hotkey #\(p.number) declined by conn#\(conn.id) client=\(conn.clientId) request=\(rid) reason=\(reason)\(Self.safeDetail(msg.string("detail"))) after=\(Self.elapsedMs(since: sent))ms")
        guard reason == "notFocused" else { return conclude(p, .fellBack(reason: "declined:\(reason)")) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - p.startedAt.uptimeNanoseconds
        if !p.candidates.isEmpty, Double(elapsed) / 1e9 < behaviour.acceptedDeadline.timeInterval {
            askNext(p, exhausted: "declined:notFocused")
        } else {
            conclude(p, .fellBack(reason: "declined:notFocused"))
        }
    }

    /// `read{requestId}`: accepted only for the live request on the connection that was asked.
    func hotkeyRead(_ conn: MockConnection, _ msg: JSONObject, requestId: String?) {
        guard let rid = requestId, let p = press, !p.done, !p.waking,
              p.requestId == rid, p.askedConnId == conn.id else {
            sendError(conn, code: "unknownRequest", message: "No pending hotkey request with that id; the read was not started.",
                      id: msg["id"], sessionId: msg.string("sessionId"))
            log("conn#\(conn.id) read for a dead hotkey request \(requestId ?? "(not a string)"); not started")
            return
        }
        var m = msg
        m["preempt"] = true   // SPEC §5.4: a hotkey read always takes over
        if let code = startRead(conn, m) {
            conclude(p, .fellBack(reason: "readRejected:\(code)"))
        } else {
            conclude(p, .routed(sessionId: msg.string("sessionId") ?? "", clientId: conn.clientId, requestId: rid,
                                accepted: p.accepted, viaWake: p.viaWake))
        }
    }

    /// The asked (or woken) connection closed or is closing.
    func hotkeyConnectionGone(_ conn: MockConnection) {
        guard let p = press, !p.done else { return }
        if (p.waking && p.wakeConnId == conn.id) || (!p.waking && p.askedConnId == conn.id) {
            log("hotkey #\(p.number) conn#\(conn.id) closed mid-request")
            conclude(p, .fellBack(reason: "disconnected"))
        }
    }

    // MARK: Wake path (SPEC §16.5)

    private func wake(_ p: HotkeyPress) {
        guard let bundleURL = p.frontmost.bundleURL else {
            return conclude(p, .fellBack(reason: "noTarget"))
        }
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              let decl = UnivocalAppDeclaration(infoDictionary: info),
              decl.hotkeyTarget,
              decl.versions.contains(where: UnivocalWire.protocolVersions.contains),
              let scheme = decl.wakeURLScheme, !scheme.isEmpty
        else {
            log("hotkey #\(p.number) \(p.frontmost.bundleId) has no usable \(UnivocalAppDeclaration.infoPlistKey) declaration")
            return conclude(p, .fellBack(reason: "noDeclaration"))
        }
        let rid = Self.requestId()
        guard let url = UnivocalWakeURL.make(scheme: scheme, requestId: rid, version: UnivocalWire.protocolVersions.max() ?? 1) else {
            log("hotkey #\(p.number) invalid WakeURLScheme")
            return conclude(p, .fellBack(reason: "noDeclaration"))
        }
        // Create the pending request before waking (§16.5 step 1).
        p.requestId = rid
        p.waking = true
        p.viaWake = true
        log("hotkey #\(p.number) woke \(url.absoluteString)")
        let opened = behaviour.wakeOpener.map { $0(url) } ?? openWithWorkspace(url, press: p)
        guard opened else {
            log("hotkey #\(p.number) could not open the wake URL")
            return conclude(p, .fellBack(reason: "wakeFailed"))
        }
        guard !p.done else { return }   // an injected opener may have connected synchronously
        if p.wakeConnId == nil { arm(p, deadline: .now() + behaviour.wakeDeadline.timeInterval) }
    }

    private func openWithWorkspace(_ url: URL, press p: HotkeyPress) -> Bool {
        #if canImport(AppKit)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false   // the app is already frontmost: no focus churn, no Dock bounce
        config.addsToRecentItems = false
        let rid = p.requestId
        let number = p.number
        NSWorkspace.shared.open(url, configuration: config) { [weak self] _, error in
            guard error != nil, let self else { return }
            self.queue.async {
                guard let cur = self.press, cur.requestId == rid, cur.waking, !cur.done else { return }
                self.log("hotkey #\(number) opening the wake URL failed")
                self.conclude(cur, .fellBack(reason: "wakeFailed"))
            }
        }
        return true
        #else
        return false
        #endif
    }

    /// `hello{wakeRequestId}`: claims the pending wake only if the connection also resolves to F.
    func claimWake(_ conn: MockConnection, requestId: String) {
        guard let p = press, !p.done, p.waking, p.requestId == requestId, p.wakeConnId == nil else {
            log("conn#\(conn.id) wakeRequestId=\(requestId) matches no pending wake; ordinary hello")
            return
        }
        guard resolves(conn, p.frontmost) else {
            log("conn#\(conn.id) wakeRequestId=\(requestId) does not resolve to \(p.frontmost.bundleId); ordinary hello")
            return
        }
        p.wakeConnId = conn.id
        p.timer?.cancel()
        p.timer = nil
        log("hotkey #\(p.number) conn#\(conn.id) answers the wake request=\(requestId)")
    }

    /// Consent prompt for the woken connection: the wake budget is suspended (§16.5 step 4).
    func wakeConsentPending(_ conn: MockConnection) {
        guard let p = press, !p.done, p.waking, p.wakeConnId == conn.id else { return }
        p.timer?.cancel()
        p.timer = nil
        log("hotkey #\(p.number) wake budget suspended while consent is pending")
    }

    func wakeConsentDenied(_ conn: MockConnection) {
        guard let p = press, !p.done, p.waking, p.wakeConnId == conn.id else { return }
        conclude(p, .fellBack(reason: "consentDenied"))
    }

    /// Right after `welcome` on the woken connection: deliver the pending request (§16.5 step 5).
    func wokenConnectionReady(_ conn: MockConnection) {
        guard let p = press, !p.done, p.waking, p.wakeConnId == conn.id, let rid = p.requestId else { return }
        guard conn.capabilities.contains("hotkey-target") else {
            log("hotkey #\(p.number) woken conn#\(conn.id) did not announce hotkey-target")
            return conclude(p, .fellBack(reason: "noTarget"))
        }
        ask(p, conn, requestId: rid)
    }

    // MARK: Timers and the outcome

    private func arm(_ p: HotkeyPress, deadline: DispatchTime) {
        p.timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: deadline, leeway: .milliseconds(1))
        t.setEventHandler { [weak self, weak p] in
            guard let self, let p, !p.done, self.press === p else { return }
            let reason = p.waking ? "wakeTimeout" : (p.accepted ? "acceptedTimeout" : "answerTimeout")
            self.log("hotkey #\(p.number) \(reason) request=\(p.requestId ?? "-")")
            self.conclude(p, .fellBack(reason: reason))
        }
        p.timer = t
        t.resume()
    }

    /// Records the one outcome of `p`, runs the fallback unless superseded, completes the press.
    func conclude(_ p: HotkeyPress, _ outcome: MockHotkeyOutcome) {
        guard !p.done else { return }
        p.done = true
        p.timer?.cancel()
        p.timer = nil
        if press === p { press = nil }   // the request id is dead from now on
        outcomes.append(outcome)
        if case .fellBack(let reason) = outcome, reason != "superseded" {
            fallbackCount += 1
            if let a = active {
                log("hotkey #\(p.number) fallback preempts session=\(a.sessionId)")
                a.finish("preempted", by: "Univocal")
            }
            log("hotkey #\(p.number) fallback: Univocal would read \(p.frontmost.bundleId)'s selection in its own panel")
        }
        let ms = Self.elapsedMs(since: p.startedAt)
        log("hotkey #\(p.number) outcome: \(outcome) after=\(ms)ms")
        p.completion(outcome)
    }

    // MARK: Console

    func consoleFrontmost(_ args: String) -> String {
        let a = args.split(separator: " ").map(String.init)
        guard let first = a.first else {
            return "frontmost: \(frontmost.map { "\($0)" } ?? "none") — usage: frontmost <bundle-id> [pid] [bundle-path] | <pid> | self | none"
        }
        switch first {
        case "none":
            setFrontmost(nil)
            return "frontmost: none"
        case "self":
            setFrontmost(MockFrontmost(pid: getpid(), bundleId: behaviour.serverBundleId))
            return "frontmost: the mock itself (\(behaviour.serverBundleId))"
        default:
            break
        }
        if a.count == 1, let pid = pid_t(first) {
            // A bare pid: derive the bundle from the executable path.
            let exe = ProcessAncestry.executablePath(of: pid)
            let bundle = exe.flatMap(Self.enclosingAppBundle)
            let id = bundle.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? exe.map { ($0 as NSString).lastPathComponent } ?? "pid:\(pid)"
            setFrontmost(MockFrontmost(pid: pid, bundleId: id, bundleURL: bundle))
            return "frontmost: \(frontmost.map { "\($0)" } ?? "none")\(exe == nil ? " (no such process)" : "")"
        }
        var pid: pid_t?
        var url: URL?
        if a.count > 1 {
            guard let p = pid_t(a[1]) else { return "frontmost: pid must be an integer" }
            pid = p
        }
        if a.count > 2 {
            url = URL(fileURLWithPath: (a[2...].joined(separator: " ") as NSString).expandingTildeInPath, isDirectory: true)
        }
        #if canImport(AppKit)
        if pid == nil || url == nil, let app = NSRunningApplication.runningApplications(withBundleIdentifier: first).first {
            pid = pid ?? app.processIdentifier
            url = url ?? app.bundleURL
        }
        #endif
        setFrontmost(MockFrontmost(pid: pid, bundleId: first, bundleURL: url))
        return "frontmost: \(frontmost.map { "\($0)" } ?? "none")"
    }

    func consoleHotkey(_ arg: String) -> String {
        let prefer = UnivocalReadRequest.Preference(rawValue: arg.trimmingCharacters(in: .whitespaces)) ?? .selection
        startPress(prefer: prefer) { _ in }   // the outcome is logged by `conclude`
        return "hotkey pressed (prefer \(prefer.rawValue)); the outcome follows in the log"
    }

    // MARK: Helpers

    static func requestId() -> String { "h" + shortId() }

    static func millis(_ d: Duration) -> Int { Int((d.timeInterval * 1000).rounded()) }

    static func elapsedMs(since t: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1_000_000)
    }

    /// `readDecline.detail` is client-supplied: log it only when it is a short neutral token.
    static func safeDetail(_ detail: String?) -> String {
        guard let d = detail, !d.isEmpty else { return "" }
        let ok = d.count <= 40 && d.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._:- ".unicodeScalars.contains($0) }
        return ok ? " detail=\(d)" : " detail=<\(d.count) chars withheld>"
    }

    static func enclosingAppBundle(_ path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
