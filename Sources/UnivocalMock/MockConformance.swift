// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import UnivocalClient

// MARK: - Public API

public struct ConformanceOptions: Sendable {
    /// `<ConnectDir>` of the server under test.
    public var directory: URL
    /// Expect consent to be granted without a human (`UNIVOCAL_CONNECT_AUTOGRANT=1` dev builds, or the mock).
    public var autograntExpected = false
    /// How long to wait for session events (a real engine may cold-start).
    public var eventTimeout: TimeInterval = 20
    /// How long to wait for a human to answer the consent prompt.
    public var consentTimeout: TimeInterval = 130
    public var clientId = "dev.univocal.conformance-probe"
    public var clientName = "Univocal Connect probe"
    /// Progress lines ("waiting for approval…"); never text content.
    public var progress: (@Sendable (String) -> Void)?
    /// > 0: also probe hotkey routing (S37, S43) by waiting this long for a `readRequest` —
    /// a human presses Univocal's read hotkey with the probe's terminal frontmost (the probe
    /// resolves to it by ancestry), or `hotkeyTrigger` simulates the press.
    public var hotkeyPressTimeout: TimeInterval = 0
    /// Called once the probe's `hotkey-target` connection is ready (tests: `MockServer.simulateHotkey`).
    public var hotkeyTrigger: (@Sendable () -> Void)?

    public init(directory: URL) {
        self.directory = directory
    }
}

public struct ConformanceResult: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable { case pass = "PASS", fail = "FAIL", skip = "SKIP" }
    public var item: String
    public var status: Status
    public var detail: String
}

/// The live-server probe of CONFORMANCE.md: evaluates every server item (S1…S53) it
/// can from the outside and reports PASS / FAIL / SKIP. It reads short fixture texts,
/// so a real Univocal will speak briefly; every session is stopped right away.
public enum MockConformance {
    public static let items: [String] = (1...53).map { "S\($0)" }

    /// Items that need a human, a second account, or a code/log review; always SKIP.
    public static let manualItems: Set<String> = ["S3", "S9", "S13", "S14", "S17", "S21", "S34", "S36",
                                                  "S38", "S39", "S40", "S41", "S46", "S47", "S49", "S51", "S52", "S53"]

    public static func run(_ options: ConformanceOptions) async -> [ConformanceResult] {
        await withCheckedContinuation { cont in
            Thread.detachNewThread {
                let probe = Probe(options)
                probe.run()
                cont.resume(returning: probe.results())
            }
        }
    }

    public static func format(_ results: [ConformanceResult]) -> String {
        results.map { r in
            let pad = r.item.padding(toLength: 4, withPad: " ", startingAt: 0)
            return "\(pad) \(r.status.rawValue)\(r.detail.isEmpty ? "" : "  \(r.detail)")"
        }.joined(separator: "\n")
    }
}

// MARK: - Probe

private final class Probe {
    struct Failure: Error { let item: String; let detail: String }

    let o: ConformanceOptions
    private var status: [String: ConformanceResult.Status] = [:]
    private var details: [String: [String]] = [:]
    private var socketPath = ""
    private var token: String?
    private var welcome: JSONObject = [:]
    private var errorsSeen: [JSONObject] = []
    private var maxFrameBytes = 1_048_576
    private var maxTextBytes = 8_388_608
    private var rateMax = 4.0

    static let fixture = "Revenue reached $5B.\n\nNext year 👍🏽 looks brighter.\r\nÜnïcode line ends here. 中文 句子 测试.\nLast line"

    init(_ options: ConformanceOptions) {
        o = options
    }

    func results() -> [ConformanceResult] {
        MockConformance.items.map { item in
            let d = (details[item] ?? []).joined(separator: "; ")
            if let s = status[item] { return ConformanceResult(item: item, status: s, detail: d) }
            if MockConformance.manualItems.contains(item) { return ConformanceResult(item: item, status: .skip, detail: "manual") }
            return ConformanceResult(item: item, status: .skip, detail: d.isEmpty ? "not probed" : d)
        }
    }

    // MARK: Recording

    private func pass(_ item: String, _ detail: String = "") {
        if status[item] != .fail { status[item] = .pass }
        if !detail.isEmpty, details[item]?.contains(detail) != true { details[item, default: []].append(detail) }
    }

    private func fail(_ item: String, _ detail: String) {
        status[item] = .fail
        details[item, default: []].append(detail)
    }

    private func skip(_ item: String, _ detail: String) {
        if status[item] == nil { status[item] = .skip }
        details[item, default: []].append(detail)
    }

    private func check(_ item: String, _ ok: Bool, _ detail: String) {
        ok ? pass(item) : fail(item, detail)
    }

    private func say(_ s: String) { o.progress?(s) }

    // MARK: Run

    func run() {
        guard discovery() else { return }
        firstMessageRules()
        guard acquireToken() else { return }
        do {
            try basicMessaging()
            try frameLimits()
            try sessions()
            try preemption()
            try chunking()
        } catch let f as Failure {
            fail(f.item, f.detail)
        } catch {
            fail("S32", "probe aborted: \(error)")
        }
        hotkeyRouting()
        errorShape()
        webSocketOrigin()
        skip("S15", "needs several prompts; covered by the mock's tests")
        skip("S31", "needs a non-reading client; covered by the mock's tests")
        for item in ["S42", "S44", "S48"] { skip(item, "needs scripted timing or several apps; covered by the mock's tests") }
    }

    // MARK: S1, S2, S8 — discovery

    private func discovery() -> Bool {
        let dir = o.directory
        let fileURL = UnivocalPaths.discoveryFileURL(in: dir)
        var st = stat()
        if stat(dir.path, &st) == 0 {
            check("S2", st.st_mode & 0o777 == 0o700, String(format: "ConnectDir mode %o (want 700)", st.st_mode & 0o777))
        } else {
            fail("S2", "ConnectDir missing")
        }
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("S8", "no readable connect.json in \(dir.path)")
            fail("S1", "server not discoverable")
            return false
        }
        if stat(fileURL.path, &st) == 0 {
            check("S8", st.st_mode & 0o777 == 0o600, String(format: "connect.json mode %o (want 600)", st.st_mode & 0o777))
        }
        let missing = ["protocol", "versions", "socket", "pid", "server"].filter { obj[$0] == nil }
        check("S8", missing.isEmpty, "connect.json lacks \(missing.joined(separator: ","))")
        check("S8", obj["protocol"] as? String == UnivocalWire.protocolName, "protocol is not univocal-connect")
        guard let d = UnivocalLocator.discovery(in: dir) else {
            fail("S8", "connect.json unparsable or its pid is not alive")
            return false
        }
        pass("S8", "pid \(d.pid) alive; removal on shutdown not probed")
        socketPath = d.socketPath
        let wellKnown = UnivocalPaths.wellKnownSocketPath(in: dir)
        var sst = stat()
        guard lstat(socketPath, &sst) == 0, sst.st_mode & S_IFMT == S_IFSOCK else {
            fail("S1", "no socket at \(socketPath)")
            return false
        }
        check("S2", sst.st_mode & 0o777 == 0o600, String(format: "socket mode %o (want 600)", sst.st_mode & 0o777))
        if socketPath != wellKnown {
            let parent = (socketPath as NSString).deletingLastPathComponent
            var pst = stat()
            if stat(parent, &pst) == 0 {
                check("S2", pst.st_mode & 0o777 == 0o700, String(format: "fallback socket dir mode %o (want 700)", pst.st_mode & 0o777))
            }
        }
        pass("S2", "stale-socket unlink not probed")
        if socketPath == wellKnown {
            pass("S1", "socket at <ConnectDir>/connect.sock")
        } else if !UnivocalPaths.socketPathFits(wellKnown) {
            pass("S1", "well-known path too long; advertised \(socketPath)")
        } else {
            pass("S1", "advertised socket differs from the well-known path (allowed; clients prefer connect.json)")
        }
        return true
    }

    // MARK: S10, S11 — before hello

    private func hello(token: String?, versions: [Int] = [1], proto: String = UnivocalWire.protocolName,
                       hotkeyTarget: Bool = false) -> JSONObject {
        var caps: [JSONValue] = ["word-events", "sentence-events", "progress"]
        if hotkeyTarget { caps.append("hotkey-target") }
        var m: JSONObject = [
            "type": "hello", "protocol": .string(proto), "versions": .array(versions.map { .int($0) }),
            "client": ["id": .string(o.clientId), "name": .string(o.clientName), "version": "1"],
            "capabilities": .array(caps),
        ]
        if let token { m["token"] = .string(token) }
        return m
    }

    private func connectRaw() throws -> RawConnectClient {
        do {
            return try RawConnectClient(path: socketPath)
        } catch {
            throw Failure(item: "S1", detail: "cannot connect: \(error)")
        }
    }

    /// Expects a fatal `error{code}` and the connection closing right after.
    private func expectFatal(_ c: RawConnectClient, code: String, item: String, what: String) {
        do {
            let e = try c.expect("error", timeout: 5)
            errorsSeen.append(e)
            check(item, e.string("code") == code, "\(what): got error \(e.string("code") ?? "?"), want \(code)")
            check(item, e.bool("fatal") == true, "\(what): error not marked fatal")
            let closed = c.readUntilClosed(timeout: 3).closed
            check(item, closed, "\(what): connection stayed open after a fatal error")
            check("S32", closed, "fatal \(code) not followed by close")
        } catch {
            fail(item, "\(what): no error reply (\(error))")
        }
    }

    private func firstMessageRules() {
        if let c = try? connectRaw() {
            try? c.send(["type": "ping", "id": 1])
            expectFatal(c, code: "protocolError", item: "S10", what: "ping before hello")
        }
        if let c = try? connectRaw() {
            try? c.send(hello(token: nil, proto: "not-univocal"))
            expectFatal(c, code: "protocolError", item: "S10", what: "hello with a foreign protocol")
        }
        if let c = try? connectRaw() {
            try? c.send(hello(token: nil, versions: [99]))
            do {
                let e = try c.expect("error", timeout: 5)
                errorsSeen.append(e)
                check("S11", e.string("code") == "unsupportedVersion", "got \(e.string("code") ?? "?")")
                check("S11", e.bool("fatal") == true, "not fatal")
                check("S11", (e.array("versions") ?? []).contains { $0.intValue == 1 }, "reply lacks versions:[1]")
                check("S11", c.readUntilClosed(timeout: 3).closed, "connection stayed open")
            } catch {
                fail("S11", "no error reply (\(error))")
            }
        }
    }

    // MARK: S12, S16, S18, S33 — consent and welcome

    private func acquireToken() -> Bool {
        guard let c = try? connectRaw() else {
            fail("S12", "cannot connect")
            return false
        }
        do {
            try c.send(hello(token: nil))
            guard let first = try c.next(timeout: 10) else {
                fail("S12", "no reply to hello")
                return false
            }
            if first.messageType == "welcome" {
                fail("S12", "welcome without consent for a token-less hello (auto-grant without consentPending)")
                return false
            }
            guard first.messageType == "consentPending" else {
                fail("S12", "first reply was \(first.messageType ?? "?"), want consentPending")
                return false
            }
            pass("S12", "consentPending on first contact")
            if !o.autograntExpected { say("Approve “\(o.clientName)” in Univocal (waiting up to \(Int(o.consentTimeout)) s)…") }
            let wait = o.autograntExpected ? 10 : o.consentTimeout
            guard let answer = try c.next(timeout: wait) else {
                fail("S12", "consent not answered in \(Int(wait)) s")
                return false
            }
            if answer.messageType == "consentDenied" {
                fail("S12", "consent denied (\(answer.string("reason") ?? "?")); remaining items need a grant")
                return false
            }
            guard answer.messageType == "consentGranted", let t = answer.string("token") else {
                fail("S12", "got \(answer.messageType ?? "?") after consentPending")
                return false
            }
            check("S12", answer.string("requestId") == first.string("requestId"), "requestId mismatch")
            let tokenOK = t.hasPrefix("uc1_") && t.count == 47
                && t.dropFirst(4).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            check("S16", tokenOK, "token is not uc1_ + 43 base64url chars")
            if tokenOK { pass("S16", "format only; hash-only storage not observable") }
            guard let w = try c.next(timeout: 5), w.messageType == "welcome" else {
                fail("S12", "consentGranted not immediately followed by welcome")
                return false
            }
            pass("S12", "consentGranted then welcome")
            token = t
            welcome = w
            c.close()
        } catch {
            fail("S12", "handshake failed: \(error)")
            return false
        }
        let limits = welcome.object("limits") ?? [:]
        maxFrameBytes = limits.int("maxFrameBytes") ?? 0
        maxTextBytes = limits.int("maxTextBytes") ?? 8_388_608
        let rate = limits.object("rate") ?? [:]
        let lo = rate.double("min") ?? .nan, hi = rate.double("max") ?? .nan
        rateMax = hi
        check("S33", maxFrameBytes >= 1_048_576, "maxFrameBytes \(maxFrameBytes) < 1048576")
        check("S33", lo <= 1 && 1 <= hi, "rate range \(lo)…\(hi) excludes 1")
        check("S33", welcome.int("version") == 1, "welcome.version is not 1")
        let identity = welcome.object("grant")?.string("identity") ?? ""
        let verified = identity.range(of: "^[A-Z0-9]{10}:.+$", options: .regularExpression) != nil
        check("S18", verified || identity == "unverified:\(o.clientId)", "unexpected identity \"\(identity)\"")
        pass("S18", "identity \(identity)")

        // Token reuse: a new connection with the token gets welcome without a prompt.
        do {
            let c2 = try authed()
            c2.close()
            pass("S12", "token accepted on reconnect")
        } catch {
            fail("S12", "stored token not accepted: \(error)")
            return false
        }
        // Identity binding: the same token under another client.id must not be accepted silently.
        if let c3 = try? connectRaw() {
            var h = hello(token: token)
            h["client"] = ["id": .string(o.clientId + ".other"), "name": .string(o.clientName), "version": "1"]
            try? c3.send(h)
            if let m = try? c3.next(timeout: 5) {
                check("S18", m.messageType != "welcome", "token bound to \(o.clientId) accepted for another client.id")
                if m.messageType == "consentPending" { pass("S18", "token under another client.id re-prompts") }
            }
            c3.close()   // abandons that prompt; a real Univocal may show it briefly
        }
        return true
    }

    /// A connection authorised with the probe's token.
    private func authed(hotkeyTarget: Bool = false) throws -> RawConnectClient {
        let c = try connectRaw()
        try c.send(hello(token: token, hotkeyTarget: hotkeyTarget))
        let m = try c.next(timeout: 10)
        guard m?.messageType == "welcome" else {
            throw Failure(item: "S12", detail: "token not accepted (got \(m?.messageType ?? "nothing"))")
        }
        return c
    }

    // MARK: S5, S6, S7 — basic messaging

    private func basicMessaging() throws {
        let c = try authed()
        defer { c.close() }
        try c.send(["type": "ping", "id": "p-1"])
        let p = try c.expect("pong", timeout: 5)
        check("S7", p["id"] == .string("p-1"), "pong does not echo a string id")
        try c.send(["type": "ping", "id": 42, "x-unknown-field": ["a": 1]])
        let p2 = try c.expect("pong", timeout: 5)
        check("S7", p2["id"] == .int(42), "pong does not echo an integer id")
        check("S6", p2["id"] == .int(42), "ping with an unknown field not answered")

        try c.send(["type": "x-probe-unknown", "id": 7])
        let e = try c.next(timeout: 5)
        if let e, e.messageType == "error" { errorsSeen.append(e) }
        check("S6", e?.messageType == "error" && e?.string("code") == "unknownType" && e?.bool("fatal") == false
              && e?["id"] == .int(7), "unknown type with id: want error{unknownType, id:7, fatal:false}")
        try c.send(["type": "x-probe-unknown"])
        try c.send(["type": "ping", "id": 8])
        let after = try c.next(timeout: 5)
        check("S6", after?.messageType == "pong" && after?["id"] == .int(8), "unknown type without id was answered")

        try c.sendRaw("{\"type\":\"ping\",\"id\":9}\r\n")
        let p3 = try c.next(timeout: 5)
        check("S5", p3?.messageType == "pong" && p3?["id"] == .int(9), "\\r\\n-terminated frame not accepted")
    }

    // MARK: S4, S5 — frame limits and malformed JSON

    private func frameLimits() throws {
        // A frame of exactly 1 MiB (including the newline) must be accepted.
        let c = try authed()
        let shell = try UnivocalWire.encode(["type": "ping", "id": 11, "pad": ""])
        let padLength = 1_048_576 - shell.count - 1
        let big = try UnivocalWire.frame(["type": "ping", "id": 11, "pad": .string(String(repeating: "a", count: padLength))])
        check("S4", big.count == 1_048_576, "probe built a \(big.count)-byte frame")
        do {
            try c.sendRaw(big)
        } catch {
            fail("S4", "server closed while receiving a 1 MiB frame")
        }
        let p = try? c.next(timeout: 10)
        check("S4", p?.messageType == "pong" && p?["id"] == .int(11),
              "1 MiB frame not accepted (got \(p?.messageType ?? "nothing") \(p?.string("code") ?? ""))")
        c.close()

        // Oversize: maxFrameBytes + 64 bytes with no newline yet → protocolError, fatal.
        let c2 = try authed()
        let oversize = Data(repeating: 0x61, count: max(maxFrameBytes, 1_048_576) + 64)
        try? c2.sendRaw(oversize)   // the server may close mid-write
        expectFatal(c2, code: "protocolError", item: "S4", what: "oversize frame")

        let c3 = try authed()
        try c3.sendRaw("{\"type\": \"ping\", oops\n")
        expectFatal(c3, code: "protocolError", item: "S5", what: "malformed JSON")
    }

    // MARK: S19, S22–S29 — one session

    private struct Collected {
        var events: [JSONObject] = []
        var others: [JSONObject] = []
    }

    /// Reads session events for `sid` until `done` returns true or the timeout passes.
    private func collect(_ c: RawConnectClient, sid: String, timeout: TimeInterval,
                         into acc: inout Collected, until done: (Collected) -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(acc) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let m = try c.next(timeout: remaining) else { return }
            if m.string("sessionId") == sid { acc.events.append(m) } else { acc.others.append(m) }
            if m.messageType == "error" { errorsSeen.append(m) }
        }
    }

    private func sessions() throws {
        let a = try authed()
        let b = try authed()
        defer { a.close(); b.close() }
        let text = Self.fixture
        let units = Array(text.utf16)
        let sid = "probe-1"

        try a.send(["type": "read", "id": 1, "sessionId": .string(sid), "text": .string(text), "lang": "en", "meta": ["title": "probe"]])
        guard let ok = try a.next(timeout: 10) else { throw Failure(item: "S19", detail: "no reply to read") }
        if ok.messageType == "error" { errorsSeen.append(ok) }
        guard ok.messageType == "ok", ok["id"] == .int(1) else {
            throw Failure(item: "S19", detail: "read answered with \(ok.messageType ?? "?") \(ok.string("code") ?? "")")
        }
        var acc = Collected()
        try collect(a, sid: sid, timeout: o.eventTimeout, into: &acc) { !$0.events.isEmpty }
        let first = acc.events.first
        check("S19", first?.messageType == "state" && first?.string("state") == "loading", "first session event is not state{loading}")

        // Wait for a few words (a real engine may need a cold start).
        try collect(a, sid: sid, timeout: o.eventTimeout, into: &acc) { acc in
            acc.events.filter { $0.messageType == "word" }.count >= 4 || acc.events.contains { $0.messageType == "ended" }
        }
        let words = acc.events.filter { $0.messageType == "word" }
        if words.isEmpty {
            fail("S26", "no word events within \(Int(o.eventTimeout)) s")
        }
        validateRanges(acc.events, units: units)

        // S19: sessionId reuse while live.
        try a.send(["type": "read", "id": 2, "sessionId": .string(sid), "text": "Again."])
        let reuse = try a.expect("error", timeout: 5, where: { $0["id"] == .int(2) }) { m in
            if m.string("sessionId") == sid { acc.events.append(m) }
        }
        errorsSeen.append(reuse)
        check("S19", reuse.string("code") == "sessionExists", "reused sessionId: got \(reuse.string("code") ?? "?")")

        // S22: non-owner and unknown session.
        try b.send(["type": "pause", "id": 3, "sessionId": .string(sid)])
        let notOwner = try b.expect("error", timeout: 5, where: { $0["id"] == .int(3) })
        errorsSeen.append(notOwner)
        check("S22", notOwner.string("code") == "notOwner", "control from a non-owner: got \(notOwner.string("code") ?? "?")")
        try a.send(["type": "pause", "id": 4, "sessionId": "probe-no-such-session"])
        let noSession = try a.expect("error", timeout: 5, where: { $0["id"] == .int(4) }) { m in
            if m.string("sessionId") == sid { acc.events.append(m) }
        }
        errorsSeen.append(noSession)
        check("S22", noSession.string("code") == "noSession", "unknown session: got \(noSession.string("code") ?? "?")")

        // S23: seek out of range, then in range.
        try a.send(["type": "seek", "id": 5, "sessionId": .string(sid), "offset": 99_999])
        let bad = try a.expect("error", timeout: 5, where: { $0["id"] == .int(5) }) { m in
            if m.string("sessionId") == sid { acc.events.append(m) }
        }
        errorsSeen.append(bad)
        check("S23", bad.string("code") == "invalidOffset" && bad.bool("fatal") == false, "seek 99999: got \(bad.string("code") ?? "?")")
        let target = 22   // start of "Next year…"
        try a.send(["type": "seek", "id": 6, "sessionId": .string(sid), "offset": .int(target)])
        _ = try a.expect("ok", timeout: 5, where: { $0["id"] == .int(6) }) { m in
            if m.string("sessionId") == sid { acc.events.append(m) }
        }
        var afterSeek = Collected()
        try collect(a, sid: sid, timeout: o.eventTimeout, into: &afterSeek) { acc in
            acc.events.contains { $0.messageType == "word" || $0.messageType == "ended" }
        }
        if let w = afterSeek.events.first(where: { $0.messageType == "word" }) {
            check("S23", (w.int("end") ?? 0) > target, "first word after seek ends at \(w.int("end") ?? -1), not after \(target)")
        } else {
            fail("S23", "no word after an in-range seek")
        }
        check("S23", !afterSeek.events.contains { $0.messageType == "state" && $0.string("state") == "paused" }, "seek changed the play state")
        acc.events += afterSeek.events

        // S24: rate clamp.
        try a.send(["type": "setRate", "id": 7, "sessionId": .string(sid), "rate": 100])
        _ = try a.expect("ok", timeout: 5, where: { $0["id"] == .int(7) }) { m in
            if m.string("sessionId") == sid { acc.events.append(m) }
        }
        let rateEvent = try a.expect("rate", timeout: 5, where: { $0.string("sessionId") == sid }) { m in
            if m.string("sessionId") == sid { acc.events.append(m) }
        }
        let r = rateEvent.double("rate") ?? .nan
        check("S24", r <= rateMax + 1e-9, "setRate 100 reported \(r) > max \(rateMax)")
        try a.send(["type": "setRate", "sessionId": .string(sid), "rate": 1])

        validateRanges(acc.events, units: units)

        // S25: stop → ok, ended{stopped}, then nothing for the session.
        try a.send(["type": "stop", "id": 8, "sessionId": .string(sid)])
        _ = try a.expect("ok", timeout: 5, where: { $0["id"] == .int(8) })
        let ended = try a.expect("ended", timeout: 5, where: { $0.string("sessionId") == sid })
        check("S25", ended.string("reason") == "stopped", "stop ended with \(ended.string("reason") ?? "?")")
        try a.send(["type": "ping", "id": 9])
        var trailing: [JSONObject] = []
        _ = try a.expect("pong", timeout: 5, where: { $0["id"] == .int(9) }) { trailing.append($0) }
        check("S25", !trailing.contains { $0.string("sessionId") == sid }, "messages for the session after ended")

        // S27: the observer saw nothing about the session.
        try b.send(["type": "ping", "id": 10])
        var seenByB: [JSONObject] = []
        _ = try b.expect("pong", timeout: 5, where: { $0["id"] == .int(10) }) { seenByB.append($0) }
        check("S27", !seenByB.contains { $0.string("sessionId") == sid }, "a non-owner received events for the session")
        pass("S25")
        pass("S27")
    }

    private func validateRanges(_ events: [JSONObject], units: [UInt16]) {
        let len = units.count
        var currentSentence: Range<Int>?
        var sawExpansion = false
        var lastWord: Range<Int>?
        for e in events {
            guard let t = e.messageType, t == "word" || t == "sentence" else { continue }
            guard let s = e.int("start"), let en = e.int("end") else {
                fail("S26", "\(t) without integer start/end")
                continue
            }
            guard s >= 0, s < en, en <= len else {
                fail("S26", "\(t) range [\(s),\(en)) invalid for length \(len)")
                continue
            }
            if UTF16.isTrailSurrogate(units[s]) || UTF16.isLeadSurrogate(units[en - 1]) {
                fail("S28", "\(t) [\(s),\(en)) splits a surrogate pair")
            }
            let slice = String(decoding: units[s..<en], as: UTF16.self)
            if t == "sentence" {
                currentSentence = s..<en
                check("S29", !slice.contains("\n\n"), "sentence [\(s),\(en)) spans a blank line")
            } else {
                check("S28", !slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "word [\(s),\(en)) is only whitespace")
                if let cs = currentSentence {
                    check("S26", cs.lowerBound <= s && en <= cs.upperBound, "word [\(s),\(en)) outside the current sentence")
                } else {
                    fail("S26", "word [\(s),\(en)) before any sentence event")
                }
                if lastWord == s..<en { sawExpansion = true }
                lastWord = s..<en
            }
        }
        if !events.isEmpty {
            pass("S26")
            pass("S28", sawExpansion ? "repeated range for an expanded token observed" : "")
            pass("S29")
        }
    }

    // MARK: S20, S27 — preemption across connections

    private func preemption() throws {
        let a = try authed()
        let b = try authed()
        defer { a.close(); b.close() }
        try a.send(["type": "read", "id": 1, "sessionId": "probe-2", "text": "Preemption test one. It keeps going for a while."])
        _ = try a.expect("ok", timeout: 10, where: { $0["id"] == .int(1) })
        try b.send(["type": "read", "id": 2, "sessionId": "probe-3", "text": "Second reader.", "preempt": false])
        let busy = try b.expect("error", timeout: 5, where: { $0["id"] == .int(2) })
        errorsSeen.append(busy)
        check("S20", busy.string("code") == "busy", "preempt:false while busy: got \(busy.string("code") ?? "?")")
        try b.send(["type": "read", "id": 3, "sessionId": "probe-3", "text": "Second reader takes over."])
        _ = try b.expect("ok", timeout: 10, where: { $0["id"] == .int(3) })
        var aSaw: [JSONObject] = []
        let ended = try a.expect("ended", timeout: 10, where: { $0.string("sessionId") == "probe-2" }) { aSaw.append($0) }
        check("S20", ended.string("reason") == "preempted", "first owner got ended{\(ended.string("reason") ?? "?")}")
        try b.send(["type": "stop", "id": 4, "sessionId": "probe-3"])
        _ = try b.expect("ended", timeout: 10, where: { $0.string("sessionId") == "probe-3" })
        try a.send(["type": "ping", "id": 5])
        _ = try a.expect("pong", timeout: 5, where: { $0["id"] == .int(5) }) { aSaw.append($0) }
        check("S27", !aSaw.contains { $0.string("sessionId") == "probe-3" }, "first owner received events for the preempting session")
        pass("S20")
    }

    // MARK: S30 — chunking and the size limit

    private func chunking() throws {
        let a = try authed()
        defer { a.close() }
        let first = "First chunk sentence. Second chunk sta"
        let second = "rts here. Final words."
        try a.send(["type": "read", "id": 1, "sessionId": "probe-4", "text": .string(first), "more": true])
        _ = try a.expect("ok", timeout: 10, where: { $0["id"] == .int(1) })
        try a.send(["type": "append", "id": 2, "sessionId": "probe-4", "text": .string(second), "more": false])
        _ = try a.expect("ok", timeout: 10, where: { $0["id"] == .int(2) })
        let boundaryWord = first.utf16.count - 3   // "starts" spans the chunk boundary
        try a.send(["type": "seek", "id": 3, "sessionId": "probe-4", "offset": .int(boundaryWord)])
        _ = try a.expect("ok", timeout: 10, where: { $0["id"] == .int(3) })
        do {
            let w = try a.expect("word", timeout: o.eventTimeout, where: { $0.string("sessionId") == "probe-4" })
            check("S30", w.int("start") == boundaryWord && w.int("end") == boundaryWord + 6,
                  "word across the chunk boundary reported as [\(w.int("start") ?? -1),\(w.int("end") ?? -1)), want [\(boundaryWord),\(boundaryWord + 6))")
        } catch {
            fail("S30", "no word after seeking into the second chunk")
        }
        try a.send(["type": "stop", "id": 4, "sessionId": "probe-4"])
        _ = try a.expect("ended", timeout: 10, where: { $0.string("sessionId") == "probe-4" })

        // Exceed maxTextBytes with frames that each fit maxFrameBytes.
        let chunk = String(repeating: "word ", count: min(maxFrameBytes, 1_048_576) / 6)
        try a.send(["type": "read", "id": 10, "sessionId": "probe-5", "text": .string(chunk), "more": true])
        _ = try a.expect("ok", timeout: 10, where: { $0["id"] == .int(10) })
        var sent = chunk.utf8.count
        var id = 11
        var limitError: JSONObject?
        while limitError == nil, sent <= maxTextBytes + chunk.utf8.count {
            try a.send(["type": "append", "id": .int(id), "sessionId": "probe-5", "text": .string(chunk), "more": true])
            sent += chunk.utf8.count
            // The error replaces the ok of the append that crossed the limit.
            let reply = try a.reply(to: .int(id), timeout: 10)
            if reply.messageType == "error" { limitError = reply }
            id += 1
        }
        if let e = limitError {
            errorsSeen.append(e)
            check("S30", e.string("code") == "limitExceeded", "over maxTextBytes: got \(e.string("code") ?? "?")")
            let ended = try a.expect("ended", timeout: 5, where: { $0.string("sessionId") == "probe-5" })
            check("S30", ended.string("reason") == "error", "over maxTextBytes ended with \(ended.string("reason") ?? "?")")
            pass("S30")
        } else {
            fail("S30", "no limitExceeded after \(sent) bytes")
        }
    }

    // MARK: S37, S43, S45, S50 — hotkey routing (Draft 2)

    private func hotkeyRouting() {
        let caps = Set((welcome.array("capabilities") ?? []).compactMap(\.stringValue))
        guard caps.contains("hotkey-routing") else {
            // A Draft 1 server would show a real prompt for a quiet hello, so probe nothing.
            for item in ["S37", "S43", "S45", "S50"] { skip(item, "server does not announce hotkey-routing (Draft 1)") }
            return
        }
        // S50: a quiet hello that needs consent → consentDenied{quiet} and close, no prompt.
        if let c = try? connectRaw() {
            var h = hello(token: nil)
            h["quiet"] = true
            try? c.send(h)
            let m = try? c.next(timeout: 5)
            check("S50", m?.messageType == "consentDenied" && m?.string("reason") == "quiet",
                  "quiet hello without a token answered \(m?.messageType ?? "nothing") \(m?.string("reason") ?? "")")
            check("S50", c.readUntilClosed(timeout: 3).closed, "connection stayed open after consentDenied{quiet}")
            pass("S50")
            c.close()
        }
        // S45: stale readAccepted/readDecline are ignored silently; read{bogus requestId} → unknownRequest, not started.
        do {
            let a = try authed(hotkeyTarget: true)
            defer { a.close() }
            try a.send(["type": "readAccepted", "requestId": "probe-bogus"])
            try a.send(["type": "readDecline", "requestId": "probe-bogus", "reason": "other"])
            try a.send(["type": "read", "id": 1, "sessionId": "probe-h1", "text": "Bogus hotkey request.", "requestId": "probe-bogus"])
            var others: [JSONObject] = []
            let e = try a.reply(to: .int(1), timeout: 5) { others.append($0) }
            errorsSeen.append(e)
            check("S45", e.messageType == "error" && e.string("code") == "unknownRequest" && e.bool("fatal") == false,
                  "read with a bogus requestId answered \(e.messageType ?? "?") \(e.string("code") ?? "")")
            try a.send(["type": "ping", "id": 2])
            _ = try a.expect("pong", timeout: 5, where: { $0["id"] == .int(2) }) { others.append($0) }
            check("S45", !others.contains { $0.string("sessionId") == "probe-h1" }, "the bogus-request read was started")
            check("S45", !others.contains { $0.messageType == "error" }, "a stale readAccepted/readDecline was answered with an error")
            pass("S45")
        } catch {
            fail("S45", "probe failed: \(error)")
        }
        // S37, S43: a real press (human or simulated) reaches only the hotkey-target connection.
        guard o.hotkeyPressTimeout > 0 else {
            skip("S37", "capability announced; delivery needs a hotkey press (check --hotkey)")
            skip("S43", "needs a hotkey press (check --hotkey)")
            return
        }
        do {
            let target = try authed(hotkeyTarget: true)
            let plain = try authed()
            defer { target.close(); plain.close() }
            say("Press Univocal's read hotkey now, with this terminal frontmost (waiting \(Int(o.hotkeyPressTimeout)) s)…")
            o.hotkeyTrigger?()
            let r = try target.expect("readRequest", timeout: o.hotkeyPressTimeout)
            let rid = r.string("requestId") ?? ""
            let answer = r.int("answerMs") ?? 0, accepted = r.int("acceptedMs") ?? 0
            check("S43", !rid.isEmpty && rid.count <= 64, "requestId missing or longer than 64")
            check("S43", r.string("trigger") == "hotkey", "trigger is \(r.string("trigger") ?? "missing")")
            check("S43", ["selection", "document"].contains(r.string("prefer") ?? ""), "prefer is \(r.string("prefer") ?? "missing")")
            check("S43", answer >= 300, "answerMs \(answer) < 300")
            check("S43", accepted >= 1500 && accepted >= answer, "acceptedMs \(accepted) < max(1500, answerMs)")
            pass("S43", "answerMs \(answer) acceptedMs \(accepted)")
            try target.send(["type": "read", "id": 1, "requestId": .string(rid), "sessionId": "probe-h2", "text": "Hotkey routing probe."])
            let ok = try target.reply(to: .int(1), timeout: 5)
            check("S37", ok.messageType == "ok", "the answering read{requestId} got \(ok.messageType ?? "?") \(ok.string("code") ?? "")")
            try target.send(["type": "stop", "id": 2, "sessionId": "probe-h2"])
            _ = try? target.reply(to: .int(2), timeout: 5)
            try plain.send(["type": "ping", "id": 3])
            var seen: [JSONObject] = []
            _ = try plain.expect("pong", timeout: 5, where: { $0["id"] == .int(3) }) { seen.append($0) }
            check("S37", !seen.contains { $0.messageType == "readRequest" }, "a connection without hotkey-target received a readRequest")
            pass("S37", "readRequest only on the hotkey-target connection")
        } catch {
            fail("S37", "no readRequest within \(Int(o.hotkeyPressTimeout)) s (\(error))")
            skip("S43", "no readRequest observed")
        }
    }

    // MARK: S32 — error shape

    private func errorShape() {
        for e in errorsSeen {
            let ok = e.string("code") != nil && e.string("message") != nil && e.bool("fatal") != nil
            check("S32", ok, "error without code/message/fatal: \(e.string("code") ?? "?")")
        }
        if !errorsSeen.isEmpty { pass("S32", "\(errorsSeen.count) errors checked") }
    }

    // MARK: S35 — WebSocket Origin refusal

    private func webSocketOrigin() {
        guard let wsString = (try? Data(contentsOf: UnivocalPaths.discoveryFileURL(in: o.directory)))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            .flatMap({ ($0["ws"] as? [String: Any])?["url"] as? String }),
            let url = URL(string: wsString), let host = url.host, let port = url.port else {
            skip("S35", "no ws advertised")
            return
        }
        check("S35", host == "127.0.0.1", "ws host \(host) is not 127.0.0.1")
        let status = httpUpgradeStatus(host: host, port: port, path: url.path.isEmpty ? "/connect" : url.path,
                                       origin: "https://example.com")
        check("S35", status == 403, "upgrade with Origin answered \(status.map(String.init) ?? "nothing"), want 403")
        if status == 403 { pass("S35", "Origin refused; text-frame and token rules not probed") }
    }

    private func httpUpgradeStatus(host: String, port: Int, path: String, origin: String) -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(host)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { return nil }
        let req = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: \(origin)\r\n\r\n"
        _ = req.withCString { Darwin.write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 12 else { return nil }
        let line = String(decoding: buf[0..<n], as: UTF8.self).split(separator: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }
}
