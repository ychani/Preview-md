// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import UnivocalClient
import UnivocalMock

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
univocal-mock — Univocal Connect v1 mock server, live-server probe, and tiny client

USAGE
  univocal-mock [serve] [--dir D] [--consent MODE] [--wpm N] [--loading-ms N]
                        [--noise] [--verbose] [--no-progress]
                        [--answer-ms N] [--accepted-ms N] [--wake-ms N]
                        [--wake-opener open|print|fail] [--no-hotkey-routing]
  univocal-mock check   [--dir D] [--autogrant-expected] [--hotkey] [--json] [--timeout S]
  univocal-mock client  [--dir D] (--text T | --file F) [--rate R] [--start N] [--progress] [--verbose]
                        [--hotkey-target] [--accept-first] [--answer-delay-ms N] [--decline REASON]
                        [--quiet] [--wake URL] [--token-file F]
  univocal-mock ctl     [--dir D] <serve console command…>

OPTIONS
  --dir D        <ConnectDir>. Defaults to $UNIVOCAL_CONNECT_DIR; there is no other
                 default, so the mock never touches the real Univocal folder.
  --consent M    allow|auto (default) · deny[:reason] · prompt|ask (answer y/n on stdin)
                 · after:<seconds> · timeout (never answers; denies after 120 s)
  --wpm N        fake reading speed, words per minute (default 180)
  --noise        inject unknown message types/fields (clients must ignore them)
  --verbose      log every session event (ids and UTF-16 offsets, never text)

HOTKEY ROUTING (SPEC §16)
  serve  --answer-ms / --accepted-ms / --wake-ms   readRequest deadlines (default 300 / 1500 / 1500)
         --wake-opener open    open the wake URL with NSWorkspace, activates=false (default)
                       print   only log it (paste it into `client --wake`) · fail  pretend it failed
         --no-hotkey-routing   behave as a Draft 1 server
  check  --hotkey      also probe hotkey routing: press Univocal's read hotkey with this
                       terminal frontmost when asked (S37, S43)
  client --hotkey-target       answer readRequests instead of reading at once: with --text/--file,
                               or --decline noContent|busy|notFocused|userDisabled|other
         --accept-first        send readAccepted first, then wait --answer-delay-ms before read
         --quiet               connect only if authorised (hello{quiet}); exit 3 if not
         --wake URL            answer a wake URL (implies --hotkey-target): hello{wakeRequestId}
         --token-file F        keep the grant token in a 0600 JSON file (default: memory only)

serve reads commands on stdin (and on <dir>/mock-control.sock, see ctl):
  y | n | preempt | revoke <identity>|all | status | help
  frontmost <bundle-id> [pid] [bundle-path] · frontmost <pid> · frontmost self · frontmost none
  hotkey [selection|document]   (prints toggled | routed … | fell back <why>)
ctl sends one console command to a running serve and prints the reply; `ctl hotkey` waits
for the press's final outcome. client reads on stdin: p | r | s | seek <offset> | rate <x>

Logs of serve never contain text content: only ids, pids, lengths, offsets and codes.
"""

struct Options {
    var command = "serve"
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var positional: [String] = []

    init(_ args: [String]) throws {
        var rest = args[...]
        if let first = rest.first, !first.hasPrefix("-") {
            command = first
            rest = rest.dropFirst()
        }
        let valued: Set<String> = ["--dir", "--consent", "--wpm", "--loading-ms", "--timeout", "--text", "--file", "--rate",
                                   "--start", "--answer-ms", "--accepted-ms", "--wake-ms", "--wake-opener",
                                   "--answer-delay-ms", "--decline", "--wake", "--token-file"]
        while let a = rest.popFirst() {
            if a == "-h" || a == "--help" {
                flags.insert("--help")
            } else if valued.contains(a) {
                guard let v = rest.popFirst() else { throw CLIError("\(a) needs a value") }
                values[a] = v
            } else if a.hasPrefix("--"), let eq = a.firstIndex(of: "="), valued.contains(String(a[..<eq])) {
                values[String(a[..<eq])] = String(a[a.index(after: eq)...])
            } else if a.hasPrefix("--") {
                flags.insert(a)
            } else {
                positional.append(a)
            }
        }
        if command != "ctl", let extra = positional.first { throw CLIError("unexpected argument \(extra)") }
    }

    func directory() throws -> URL {
        let raw = values["--dir"] ?? ProcessInfo.processInfo.environment["UNIVOCAL_CONNECT_DIR"]
        guard let raw, !raw.isEmpty else {
            throw CLIError("no directory: pass --dir <ConnectDir> or set UNIVOCAL_CONNECT_DIR")
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    func milliseconds(_ key: String) throws -> Duration? {
        guard let v = values[key] else { return nil }
        guard let n = Int(v), n >= 0 else { throw CLIError("\(key) needs a non-negative integer") }
        return .milliseconds(n)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

/// Reads stdin lines on a background thread and hands each to `handle`.
func readStdinLines(_ handle: @escaping @Sendable (String) async -> Void) {
    Thread.detachNewThread {
        while let line = readLine() {
            let sem = DispatchSemaphore(value: 0)
            Task {
                await handle(line)
                sem.signal()
            }
            sem.wait()
        }
    }
}

func onTerminate(_ body: @escaping @Sendable () async -> Void) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler {
            Task {
                await body()
                exit(0)
            }
        }
        src.resume()
        return src
    }
}

// MARK: control socket (`serve` side) and `ctl`

/// `<dir>/mock-control.sock`: one console command per connection, one reply line back.
/// Lets scripted QA drive `serve` without its stdin (`univocal-mock ctl hotkey`).
enum ControlSocket {
    static let fileName = "mock-control.sock"

    static func path(in dir: URL) -> String { dir.appendingPathComponent(fileName).path }

    static func sockaddr(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard bytes.count <= UnivocalPaths.maxSocketPathBytes else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    /// Starts accepting on a background thread; returns the path or `nil` if it cannot bind.
    static func start(in dir: URL, server: MockServer) -> String? {
        let p = path(in: dir)
        guard var addr = sockaddr(p) else { return nil }
        unlink(p)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        chmod(p, 0o600)
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 {
                    if errno == EINTR { continue }
                    return
                }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else {
                    close(c)
                    continue
                }
                Thread.detachNewThread { serveOne(c, server: server) }
            }
        }
        return p
    }

    private static func serveOne(_ fd: Int32, server: MockServer) {
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A), data.count < 65_536 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        let sem = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        Task {
            let words = line.split(separator: " ").map(String.init)
            if words.first?.lowercased() == "hotkey" {
                let prefer = UnivocalReadRequest.Preference(rawValue: words.dropFirst().first ?? "") ?? .selection
                print("\(stamp()) > ctl: hotkey (prefer \(prefer.rawValue))")
                let outcome = await server.simulateHotkey(prefer: prefer)
                box.value = "\(outcome)"
            } else {
                print("\(stamp()) > ctl: \(words.first ?? "")")
                box.value = await server.handleConsoleCommand(line)
            }
            sem.signal()
        }
        sem.wait()
        let reply = Array((box.value + "\n").utf8)
        _ = reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    final class ReplyBox: @unchecked Sendable { var value = "" }

    /// `ctl`: send one line, print the reply.
    static func send(_ line: String, dir: URL) throws -> String {
        let p = path(in: dir)
        guard var addr = sockaddr(p) else { throw CLIError("control socket path too long: \(p)") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("socket failed") }
        defer { close(fd) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw CLIError("no univocal-mock serve control socket at \(p) (is serve running with this --dir?)") }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

func ctl(_ o: Options) throws -> Never {
    let dir = try o.directory()
    guard !o.positional.isEmpty else { throw CLIError("ctl needs a console command, e.g. `ctl hotkey` or `ctl frontmost <pid>`") }
    print(try ControlSocket.send(o.positional.joined(separator: " "), dir: dir))
    exit(0)
}

// MARK: serve

func serve(_ o: Options) async throws -> Never {
    let dir = try o.directory()
    var b = MockBehaviour()
    b.verbose = o.flags.contains("--verbose")
    b.injectUnknownMessages = o.flags.contains("--noise")
    if o.flags.contains("--no-progress") { b.capabilities.remove("progress") }
    if let w = o.values["--wpm"] {
        guard let v = Double(w) else { throw CLIError("--wpm needs a number") }
        b.wordsPerMinute = v
    }
    if let l = o.values["--loading-ms"] {
        guard let v = Int(l) else { throw CLIError("--loading-ms needs an integer") }
        b.loadingDelay = .milliseconds(v)
    }
    let consent = o.values["--consent"] ?? "allow"
    switch consent {
    case "allow", "auto", "grant": b.consent = .autoGrant
    case "prompt", "ask": b.consent = .askOnStdin
    case "timeout": b.consent = .timeout
    case let s where s == "deny" || s.hasPrefix("deny:"):
        b.consent = .autoDeny(reason: s == "deny" ? "user" : String(s.dropFirst(5)))
    case let s where s.hasPrefix("after:"):
        guard let secs = Double(s.dropFirst(6)) else { throw CLIError("--consent after:<seconds>") }
        b.consent = .grantAfter(.milliseconds(Int(secs * 1000)))
    default:
        throw CLIError("unknown --consent \(consent)")
    }
    b.hotkeyRouting = !o.flags.contains("--no-hotkey-routing")
    if let d = try o.milliseconds("--answer-ms") { b.answerDeadline = d }
    if let d = try o.milliseconds("--accepted-ms") { b.acceptedDeadline = d }
    if let d = try o.milliseconds("--wake-ms") { b.wakeDeadline = d }
    let opener = o.values["--wake-opener"] ?? "open"
    switch opener {
    case "open": b.wakeOpener = nil
    case "print": b.wakeOpener = { url in print("\(stamp()) wake URL (not opened): \(url.absoluteString)"); return true }
    case "fail": b.wakeOpener = { _ in false }
    default: throw CLIError("unknown --wake-opener \(opener) (open|print|fail)")
    }
    b.logHandler = { line in print("\(stamp()) \(line)") }

    let server = MockServer(directory: dir, behaviour: b)
    try await server.start()
    let socket = await server.socketPath
    let control = ControlSocket.start(in: dir, server: server)
    print("""
    univocal-mock listening on \(socket)
      discovery  \(UnivocalPaths.discoveryFileURL(in: dir).path)
      consent    \(consent) · wpm \(b.wordsPerMinute) · loading \(b.loadingDelay)
      hotkey     \(b.hotkeyRouting ? "routing on" : "routing off (Draft 1)") · answer \(b.answerDeadline) · accepted \(b.acceptedDeadline) · wake \(b.wakeDeadline) · opener \(opener)
      clients    export UNIVOCAL_CONNECT_DIR=\(dir.path.contains(" ") ? "\"\(dir.path)\"" : dir.path)
      control    \(control ?? "unavailable (path too long)")  — e.g. univocal-mock ctl --dir … hotkey
      stdin      y | n | preempt | revoke <identity>|all | status | frontmost … | hotkey [selection|document] | help
                 (Ctrl-C quits and cleans up)
    """)
    let signals = onTerminate {
        await server.stop()
        if let control { unlink(control) }
        print("univocal-mock stopped; removed connect.json and the sockets")
    }
    readStdinLines { line in
        let reply = await server.handleConsoleCommand(line)
        print("\(stamp()) > \(reply)")
    }
    while true {
        try? await Task.sleep(for: .seconds(3600))
        _ = signals
    }
}

// MARK: check

func check(_ o: Options) async throws -> Never {
    var opts = ConformanceOptions(directory: try o.directory())
    opts.autograntExpected = o.flags.contains("--autogrant-expected")
    if let t = o.values["--timeout"] {
        guard let v = Double(t) else { throw CLIError("--timeout needs seconds") }
        opts.eventTimeout = v
    }
    if o.flags.contains("--hotkey") { opts.hotkeyPressTimeout = 20 }
    let json = o.flags.contains("--json")
    if !json { opts.progress = { print($0) } }
    let results = await MockConformance.run(opts)
    if json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try enc.encode(results), as: UTF8.self))
    } else {
        print(MockConformance.format(results))
        let counts = Dictionary(grouping: results, by: \.status).mapValues(\.count)
        print("\n\(counts[.pass] ?? 0) PASS · \(counts[.fail] ?? 0) FAIL · \(counts[.skip] ?? 0) SKIP")
    }
    exit(results.contains { $0.status == .fail } ? 1 : 0)
}

// MARK: client

func describe(_ e: ReadingEvent, in text: String) -> String {
    func quote(_ r: Range<Int>) -> String {
        guard let sr = UTF16Offsets.range(r, in: text) else { return "?" }
        let s = String(text[sr]).replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(s.count > 60 ? String(s.prefix(57)) + "…" : s)\""
    }
    switch e {
    case .state(let s, let d): return "state \(s.rawValue)\(d.map { " (\($0))" } ?? "")"
    case .sentence(let r): return "sentence [\(r.lowerBound),\(r.upperBound)) \(quote(r))"
    case .word(let r): return "  word [\(r.lowerBound),\(r.upperBound)) \(quote(r))"
    case .progress(let o): return "progress \(o)"
    case .rate(let r): return "rate \(r)"
    case .error(let err): return "error \(err.code.rawValue): \(err.message)"
    case .ended(let reason, let by): return "ended \(reason.rawValue)\(by.map { " by \($0)" } ?? "")"
    }
}

/// Grant tokens in a `0600` JSON file (`--token-file`), so `--quiet` has something to present.
actor FileTokenStore: UnivocalTokenStore {
    let url: URL

    init(path: String) {
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func token(forServer serverBundleId: String) async throws -> String? {
        load()[serverBundleId]
    }

    func setToken(_ token: String?, forServer serverBundleId: String) async throws {
        var all = load()
        all[serverBundleId] = token
        let data = try JSONEncoder().encode(all)
        let tmp = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CLIError("cannot write \(tmp.path)")
        }
        guard rename(tmp.path, url.path) == 0 else { throw CLIError("cannot write \(url.path)") }
    }
}

/// The session the stdin commands act on.
actor CurrentSession {
    var session: ReadingSession?
    func set(_ s: ReadingSession?) { session = s }
}

func printEvents(_ session: ReadingSession, text: String) async {
    for await e in session.events {
        print("\(stamp()) \(describe(e, in: text))")
    }
}

func client(_ o: Options) async throws -> Never {
    let dir = try o.directory()
    let wakeURL = o.values["--wake"]
    let hotkeyMode = o.flags.contains("--hotkey-target") || wakeURL != nil
    let decline: UnivocalDeclineReason?
    if let d = o.values["--decline"] {
        guard let r = UnivocalDeclineReason(rawValue: d) else {
            throw CLIError("--decline noContent|busy|notFocused|userDisabled|other")
        }
        decline = r
    } else {
        decline = nil
    }
    let text: String
    if let t = o.values["--text"] {
        text = t
    } else if let f = o.values["--file"] {
        text = try String(contentsOfFile: (f as NSString).expandingTildeInPath, encoding: .utf8)
    } else if hotkeyMode, decline != nil {
        text = ""
    } else {
        throw CLIError(hotkeyMode ? "client --hotkey-target needs --text, --file or --decline" : "client needs --text or --file")
    }
    let answerDelay = try o.milliseconds("--answer-delay-ms") ?? .zero
    let acceptFirst = o.flags.contains("--accept-first")
    let startOffset = Int(o.values["--start"] ?? "") ?? 0
    let rate = o.values["--rate"].flatMap(Double.init)

    var config = UnivocalConfiguration(client: .init(id: "dev.univocal.mock-cli", name: "univocal-mock client", version: "1.0"))
    config.connectDirectory = dir
    if let tf = o.values["--token-file"] {
        config.tokenStore = FileTokenStore(path: tf)
    } else {
        config.tokenStore = InMemoryTokenStore()   // every run asks for consent again
    }
    config.appLocator = { _ in nil }            // never consult LaunchServices or launch anything
    config.hotkeyTarget = hotkeyMode
    if o.flags.contains("--progress") { config.clientCapabilities.insert("progress") }
    if o.flags.contains("--verbose") { config.logger = { print("\(stamp()) \($0)") } }
    let c = UnivocalClient(configuration: config)
    let states = Task {
        for await s in c.stateUpdates() {
            switch s {
            case .awaitingConsent: print("\(stamp()) waiting for approval in the server…")
            case .connected(let info):
                print("\(stamp()) connected to \(info.name) \(info.version) via \(info.transport.rawValue) as \(info.grantIdentity); capabilities \(info.capabilities.sorted().joined(separator: ","))")
            default: print("\(stamp()) state \(s)")
            }
        }
    }
    let current = CurrentSession()
    readStdinLines { line in
        let parts = line.split(separator: " ").map(String.init)
        guard let session = await current.session else {
            print("\(stamp()) no session yet")
            return
        }
        do {
            switch parts.first ?? "" {
            case "p", "pause": try await session.pause()
            case "r", "resume": try await session.resume()
            case "s", "stop": try await session.stop()
            case "seek": try await session.seek(toUTF16Offset: Int(parts.dropFirst().first ?? "") ?? 0)
            case "rate": try await session.setRate(Double(parts.dropFirst().first ?? "") ?? 1)
            default: print("commands: p | r | s | seek <offset> | rate <x>")
            }
        } catch {
            print("\(stamp()) \(error)")
        }
    }

    do {
        if o.flags.contains("--quiet") {
            guard let info = try await c.connectIfAuthorized() else {
                print("\(stamp()) not connected: no stored token, server not running, or the quiet hello was refused (token discarded)")
                exit(3)
            }
            print("\(stamp()) quiet hello accepted (\(info.grantIdentity))")
        }

        guard hotkeyMode else {
            var req = ReadRequest(text: text)
            req.title = "univocal-mock client"
            req.rate = rate
            req.startOffset = startOffset
            let session = try await c.read(req)
            await current.set(session)
            print("\(stamp()) reading session \(session.id) (\(session.textUTF16Count) UTF-16 units)")
            await printEvents(session, text: text)
            states.cancel()
            await c.disconnect()
            exit(0)
        }

        // Hotkey target: answer every readRequest; stay connected; reconnect when the server reappears.
        let requests = c.readRequests()
        Task {
            for await req in requests {
                print("\(stamp()) readRequest \(req.id) prefer=\(req.prefer.rawValue) answerMs=\(req.answerMs) acceptedMs=\(req.acceptedMs)")
                do {
                    if let decline {
                        try await c.decline(req, reason: decline, detail: "cli")
                        print("\(stamp()) declined \(req.id) (\(decline.rawValue))")
                        continue
                    }
                    if acceptFirst {
                        try await c.accept(req)
                        print("\(stamp()) readAccepted \(req.id)")
                    }
                    if answerDelay > .zero { try await Task.sleep(for: answerDelay) }
                    var r = ReadRequest(text: text)
                    r.title = "univocal-mock client"
                    r.rate = rate
                    r.startOffset = startOffset
                    let session = try await c.read(r, answering: req)
                    await current.set(session)
                    print("\(stamp()) answered \(req.id) with session \(session.id) (\(session.textUTF16Count) UTF-16 units)")
                    Task { await printEvents(session, text: text) }
                } catch let e as UnivocalError where e.code == .unknownRequest {
                    print("\(stamp()) too late for \(req.id): the server already fell back (unknownRequest)")
                } catch {
                    print("\(stamp()) answering \(req.id) failed: \(error)")
                }
            }
        }
        if let wakeURL {
            guard let url = URL(string: wakeURL), let rid = UnivocalWakeURL.parse(url) else {
                throw CLIError("--wake: not a wake URL (<scheme>://univocal-connect/read?requestId=…)")
            }
            _ = try await c.connectForWake(requestId: rid)
        } else if !o.flags.contains("--quiet") {
            _ = try await c.connect(launchIfNeeded: false)
        }
        print("\(stamp()) waiting for hotkey requests (\(decline.map { "declining \($0.rawValue)" } ?? (acceptFirst ? "accept first" : "answering with read")))…")
        for await _ in UnivocalLocator.serverAppearances(configuration: config) {
            if case .connected = await c.state { continue }
            print("\(stamp()) server appeared; reconnecting quietly")
            _ = try? await c.connectIfAuthorized()
        }
        exit(0)
    } catch let e as UnivocalError {
        print("\(stamp()) failed: \(e.code.rawValue) — \(e.message)")
        exit(1)
    }
}

// MARK: main

do {
    let o = try Options(Array(CommandLine.arguments.dropFirst()))
    if o.flags.contains("--help") || o.command == "help" {
        print(usage)
        exit(0)
    }
    switch o.command {
    case "serve": try await serve(o)
    case "check": try await check(o)
    case "client": try await client(o)
    case "ctl": try ctl(o)
    default: throw CLIError("unknown command \(o.command)")
    }
} catch {
    FileHandle.standardError.write(Data("univocal-mock: \(error)\n\n\(usage)\n".utf8))
    exit(2)
}
