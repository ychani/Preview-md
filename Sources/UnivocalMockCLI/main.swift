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
  univocal-mock check   [--dir D] [--autogrant-expected] [--json] [--timeout S]
  univocal-mock client  [--dir D] (--text T | --file F) [--rate R] [--start N] [--progress] [--verbose]

OPTIONS
  --dir D        <ConnectDir>. Defaults to $UNIVOCAL_CONNECT_DIR; there is no other
                 default, so the mock never touches the real Univocal folder.
  --consent M    allow|auto (default) · deny[:reason] · prompt|ask (answer y/n on stdin)
                 · after:<seconds> · timeout (never answers; denies after 120 s)
  --wpm N        fake reading speed, words per minute (default 180)
  --noise        inject unknown message types/fields (clients must ignore them)
  --verbose      log every session event (ids and UTF-16 offsets, never text)

serve reads commands on stdin: y | n | preempt | revoke <identity>|all | status | help
client reads commands on stdin: p (pause) | r (resume) | s (stop) | seek <offset> | rate <x>

Logs never contain text content: only ids, lengths, offsets and codes.
"""

struct Options {
    var command = "serve"
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(_ args: [String]) throws {
        var rest = args[...]
        if let first = rest.first, !first.hasPrefix("-") {
            command = first
            rest = rest.dropFirst()
        }
        let valued: Set<String> = ["--dir", "--consent", "--wpm", "--loading-ms", "--timeout", "--text", "--file", "--rate", "--start"]
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
                throw CLIError("unexpected argument \(a)")
            }
        }
    }

    func directory() throws -> URL {
        let raw = values["--dir"] ?? ProcessInfo.processInfo.environment["UNIVOCAL_CONNECT_DIR"]
        guard let raw, !raw.isEmpty else {
            throw CLIError("no directory: pass --dir <ConnectDir> or set UNIVOCAL_CONNECT_DIR")
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
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
    b.logHandler = { line in print("\(stamp()) \(line)") }

    let server = MockServer(directory: dir, behaviour: b)
    try await server.start()
    let socket = await server.socketPath
    print("""
    univocal-mock listening on \(socket)
      discovery  \(UnivocalPaths.discoveryFileURL(in: dir).path)
      consent    \(consent) · wpm \(b.wordsPerMinute) · loading \(b.loadingDelay)
      clients    export UNIVOCAL_CONNECT_DIR=\(dir.path.contains(" ") ? "\"\(dir.path)\"" : dir.path)
      stdin      y | n | preempt | revoke <identity>|all | status | help   (Ctrl-C quits and cleans up)
    """)
    let signals = onTerminate {
        await server.stop()
        print("univocal-mock stopped; removed connect.json and the socket")
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

func client(_ o: Options) async throws -> Never {
    let dir = try o.directory()
    let text: String
    if let t = o.values["--text"] {
        text = t
    } else if let f = o.values["--file"] {
        text = try String(contentsOfFile: (f as NSString).expandingTildeInPath, encoding: .utf8)
    } else {
        throw CLIError("client needs --text or --file")
    }
    var config = UnivocalConfiguration(client: .init(id: "dev.univocal.mock-cli", name: "univocal-mock client", version: "1.0"))
    config.connectDirectory = dir
    config.tokenStore = InMemoryTokenStore()   // every run asks for consent again
    config.appLocator = { _ in nil }            // never consult LaunchServices or launch anything
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
    var req = ReadRequest(text: text)
    req.title = "univocal-mock client"
    if let r = o.values["--rate"] { req.rate = Double(r) }
    if let s = o.values["--start"] { req.startOffset = Int(s) ?? 0 }
    do {
        let session = try await c.read(req)
        print("\(stamp()) reading session \(session.id) (\(session.textUTF16Count) UTF-16 units)")
        readStdinLines { line in
            let parts = line.split(separator: " ").map(String.init)
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
        for await e in session.events {
            print("\(stamp()) \(describe(e, in: text))")
        }
        states.cancel()
        await c.disconnect()
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
    default: throw CLIError("unknown command \(o.command)")
    }
} catch {
    FileHandle.standardError.write(Data("univocal-mock: \(error)\n\n\(usage)\n".utf8))
    exit(2)
}
