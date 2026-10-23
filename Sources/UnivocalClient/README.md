# UnivocalClient — Univocal Connect for Swift

<!-- SPDX-License-Identifier: MIT · Copyright (c) 2026 NarNar Labs -->

A small Swift SDK for **Univocal Connect v1**: ask [Univocal](https://univocalapp.com)
to read text aloud and receive word- and sentence-level progress to highlight in
your own UI. The protocol is specified in
[`docs/univocal-protocol/SPEC.md`](../../docs/univocal-protocol/SPEC.md); this
package is its reference client.

* macOS 13+, Swift 5.9+, strict-concurrency clean, every public type `Sendable`.
* Imports only Foundation, Network, Security and `os` (plus AppKit, behind
  `#if canImport(AppKit)`, in `UnivocalAvailability.swift` for LaunchServices and in
  `UnivocalServerAppearances.swift` for `didLaunchApplicationNotification`).
* Implements SPEC Draft 2, including hotkey routing (§16) — see below.
* MIT licensed, independent of the app that hosts it.

## Usage

```swift
import UnivocalClient

var config = UnivocalConfiguration(client: .init(
    id: "com.example.myapp", name: "My App", version: "1.0",
    bundleId: Bundle.main.bundleIdentifier))
let univocal = UnivocalClient(configuration: config)

// Before showing a "Read aloud" button:
switch UnivocalLocator.availability(configuration: config) {
case .notInstalled:            showGetUnivocal(UnivocalLocator.downloadURL)
case .installed(_, let running): enableButton(launchesUnivocal: !running)
}

// On click. read() connects (launching Univocal in the background if needed),
// runs the consent handshake the first time, then starts a session.
var request = ReadRequest(text: documentText)        // offsets refer to exactly this string
request.title = "Q3 notes.md"                        // shown in Univocal, never logged
let session = try await univocal.read(request)

for await event in session.events {                  // buffered from creation; finishes after .ended
    await MainActor.run {
        switch event {
        case .state(let s, let detail): showState(s, detail)          // loading / playing / paused
        case .sentence(let r):          tintSentence(UTF16Offsets.nsRange(r))
        case .word(let r):              highlightWord(UTF16Offsets.nsRange(r))  // may repeat a range: don't re-animate
        case .progress, .rate:          break
        case .error(let e):             log(e.code)
        case .ended(let reason, _):     clearHighlights(); if reason == .error { showFailure() }
        }
    }
}

try await session.pause()          // resume(), stop(), seek(toUTF16Offset:), setRate(_:)
```

Connection state for a toolbar or menu — each call is an independent stream that
yields the current state first:

```swift
for await state in univocal.stateUpdates() {
    // .disconnected · .launching · .connecting · .awaitingConsent ("Waiting for approval in Univocal…") · .connected(info)
}
```

Errors are `UnivocalError` with a `code` (server codes from SPEC §10 plus client
codes such as `notInstalled`, `launchTimedOut`, `consentDenied`,
`consentTimedOut`, `textTooLarge`, `sessionEnded`) and a user-presentable
`message`. After `unauthorized` with `reason == "revoked"` the stored token is
deleted and `connect()` refuses to re-prompt for 10 minutes unless the user asks
explicitly (`forgetAuthorization()`).

### Offsets

All ranges are **UTF-16 code units** (`Range<Int>`, half-open) into the exact
`ReadRequest.text` — the same units as `NSString`/`NSRange` and JavaScript
strings. Never use `String.count`. Convert at the edge with
`UTF16Offsets.range(_:in:)` (to `Range<String.Index>`, widened so a surrogate
pair is never split) or `UTF16Offsets.nsRange(_:)`. Send `\n` line endings if
your UI counts them that way; the SDK never rewrites text.

### Long texts

`read()` chunks transparently (SPEC §8): text above 512 KiB is sent as
`read{more:true}` plus `append`s cut after the last blank line, and each frame is
kept under the server's `maxFrameBytes` even when JSON escaping inflates it.
Callers see one session with global offsets.

### Tokens

`KeychainTokenStore` (default) keeps the grant token in the login Keychain:
`kSecClassGenericPassword`, service `com.univocal.connect`, account =
`configuration.tokenAccount` — Univocal's bundle id, plus `@<connect dir>` when
the connect directory is not that server's default. A mock or a test server
(`UNIVOCAL_CONNECT_DIR`) therefore never reads or overwrites the token for the
real Univocal; QA tokens land under accounts like `com.univocal.app@/tmp/uc-qa`
and can be removed with
`security delete-generic-password -s com.univocal.connect -a 'com.univocal.app@/tmp/uc-qa'`.
`InMemoryTokenStore` is for tests, previews and CLIs; tests never use the
Keychain store (the opt-in Keychain round-trip test uses a throwaway service).

**The Keychain never holds up the handshake.** macOS ties a Keychain item to
the code signature of the app that wrote it. Ad-hoc and dev builds get a new
designated requirement with every build, so reading a token a *previous*
build saved makes macOS ask: "<App> wants to use your confidential
information stored in 'Univocal Connect token (…)'", with a password field.
The read blocks until the user answers. So the client reads the token on a
background queue and waits at most `tokenReadTimeout` (default 1 s); after
that, or on any error or denial, it says `hello` without a token and Univocal
asks for consent again. Writes and deletes are never awaited on the handshake
path. Builds signed with a Developer ID (or App Store) certificate keep a
stable designated requirement across updates and never see this prompt.

### Environment (QA only — never set in a shipped app)

| Variable | Effect |
|---|---|
| `UNIVOCAL_CONNECT_DIR` | Overrides `<ConnectDir>` (point it at a `univocal-mock` directory). |
| `UNIVOCAL_BUNDLE_ID` | Overrides the server bundle id (`com.univocal.app.dev` for dev builds). |

Tests should not mutate the process environment: use
`UnivocalConfiguration(client:environment:)` and set `connectDirectory`,
`tokenStore`, `appLocator` and `launcher` directly.

## Hotkey routing (Draft 2)

Univocal's read hotkey (⌥⇧R) can read **inside the frontmost app** when that app is a
Connect client (SPEC §16): Univocal sends the app a `readRequest`, the app answers with a
`read`, and highlighting works as for any session. Univocal's own panel stays the fallback
whenever the app declines, is too slow, or is not a target.

### 1. Announce and answer requests

```swift
var config = UnivocalConfiguration(client: …)
config.hotkeyTarget = true            // the SDK adds "hotkey-target" to hello.capabilities itself
let univocal = UnivocalClient(configuration: config)

// One long-lived consumer per app (start it before connecting).
Task {
    for await request in univocal.readRequests() {
        await handle(request)
    }
}

func handle(_ request: UnivocalReadRequest) async {
    guard let document = currentDocument() else {
        try? await univocal.decline(request, reason: .noContent); return
    }
    guard isInPreviewMode else {      // nowhere to highlight: let Univocal's panel read the selection
        try? await univocal.decline(request, reason: .other, detail: "editView"); return
    }
    do {
        try await univocal.accept(request)                  // text not in hand yet: buy time (acceptedMs)
        let (text, start) = await extractText(prefer: request.prefer)
        var read = ReadRequest(text: text)
        read.startOffset = start                            // selection start, else first visible block
        let session = try await univocal.read(read, answering: request)
        consume(session)                                    // an ordinary session from here on
    } catch let e as UnivocalError where e.code == .unknownRequest {
        // Too late: Univocal already fell back. Clear local state; no error UI, no retry.
    } catch {
        // Anything else: as for read(_:)
    }
}
```

* Answer **every** request exactly once: `read(_:answering:)` or `decline(_:reason:detail:)`,
  optionally preceded by `accept(_:)`. A second answer throws `requestAnswered`.
* Budgets are measured by Univocal from when it sent the request: some answer must
  *arrive* within `answerMs` (≥ 300 ms); after `accept` the `read` must arrive within
  `acceptedMs` (≥ 1.5 s). `request.answerDeadline` / `acceptedDeadline` are local
  estimates — aim far below them. Text already in hand → skip `accept` and `read` at once.
* `prefer == .selection` and a non-empty selection → send the **whole document** with
  `startOffset` at the selection start (highlighting continues past it). No selection, or
  `.document` → the document from the first visible block. Decline `noContent` only when
  there is no document at all (SPEC §16.12).
* Decline reasons: `noContent`, `busy` (modal, a start in flight), `notFocused` (this
  connection does not own the key window; Univocal asks another connection of the same
  app), `userDisabled`, `other` (+ a short neutral `detail` for logs — never document text).
* Pause/resume on a second press is **server-side**: the session just gets
  `.state(.paused)` / `.state(.playing)`. Never toggle locally on a request or wake URL.
* `read(_:answering:)` never connects, forces `preempt = true`, and validates like
  `read(_:)`; a locally invalid request (empty text) throws and leaves the hotkey request
  unanswered, so you can still `decline` it.
* If `hotkeyTarget` is on but no `readRequests()` stream is alive, the SDK declines at once
  (`other`, "noConsumer") so Univocal falls back without waiting.
* Requests arrive only when the server announced `hotkey-routing`; a Draft 1 Univocal never
  sends any, and the SDK never sends `readAccepted`/`readDecline` to it.

### 2. Connect at launch — quietly

A hotkey target should already be connected when the key is pressed, without ever
launching Univocal or showing a prompt at app launch (SPEC §16.9):

```swift
// At launch, and each time Univocal (re)appears:
Task {
    _ = try? await univocal.connectIfAuthorized()
    for await _ in UnivocalLocator.serverAppearances(configuration: config) {
        _ = try? await univocal.connectIfAuthorized()
    }
}
```

* `connectIfAuthorized()` connects with `hello{quiet:true}` **only** if a token is stored
  **and** `connect.json` shows a live server; otherwise it returns `nil` without opening a
  socket. It never launches Univocal and never causes a consent prompt: if the token is no
  longer valid the server answers `consentDenied{reason:"quiet"}`, the SDK deletes the token
  and returns `nil`. It throws only on transport/protocol failures; it is idempotent.
* Never call `connect()` or `read(_:)` at launch — both may launch Univocal and prompt.
  Without a token the app does nothing at launch; the first hotkey press wakes it (below),
  the user approves once, and from then on it connects at launch.
* `serverAppearances` yields the current server first (if up), then whenever a server
  appears or restarts (a vnode watch on `<ConnectDir>` plus `didLaunchApplication`).
  Cancel the consuming task to stop watching.

### 3. Declare the app and handle the wake URL

So Univocal can reach the app while it is running but not connected, declare support in
the app's `Info.plist` (SPEC Appendix B) and register the scheme in the same bundle:

```xml
<key>UnivocalConnect</key>
<dict>
    <key>Versions</key>        <array><integer>1</integer></array>
    <key>HotkeyTarget</key>    <true/>
    <key>WakeURLScheme</key>   <string>myapp</string>
</dict>
<key>CFBundleURLTypes</key>
<array><dict>
    <key>CFBundleURLName</key>    <string>com.example.myapp.url</string>
    <key>CFBundleURLSchemes</key> <array><string>myapp</string></array>
    <key>LSHandlerRank</key>      <string>Owner</string>
</dict></array>
```

Validate it in a unit test (or a debug assertion) with the helper:

```swift
let declaration = UnivocalAppDeclaration.current()          // nil: no UnivocalConnect dict
XCTAssertEqual(declaration?.problems(in: .main), [])        // e.g. "URL scheme \"myapp\" is not registered…"
// From a plist on disk: UnivocalAppDeclaration(infoDictionary:) + problems(infoDictionary:)
```

Univocal opens `myapp://univocal-connect/read?requestId=<id>&v=1` with `activates = false`.
Route it **before** any document-opening logic, and do nothing visible:

```swift
func application(_ app: NSApplication, open urls: [URL]) {
    for url in urls {
        if let requestId = UnivocalWakeURL.parse(url) {      // nil for every other URL
            Task { _ = try? await univocal.connectForWake(requestId: requestId) }
        } else {
            openDocument(url)
        }
    }
}
```

`connectForWake` connects without launching and sends `hello{wakeRequestId}` (consent may
be prompted: the user pressed the key); the matching request then arrives on
`readRequests()` right after `welcome`. Already connected → it returns at once and sends
nothing. A wake handler must not open a window, change document or activate the app
(SwiftUI: make sure the scheme does not match a `WindowGroup`'s `handlesExternalEvents`).

### 4. Trying it against the mock

```sh
swift run univocal-mock serve --dir /tmp/uc-qa --consent ask --verbose
# second terminal: a reference hotkey target that answers every request
swift run univocal-mock client --dir /tmp/uc-qa --hotkey-target --text "Hello there. Second sentence."
# serve console (or from a third terminal: swift run univocal-mock ctl --dir /tmp/uc-qa <command>)
frontmost <client pid>          # or: frontmost <bundle-id> [pid] [bundle-path] · frontmost none
hotkey                          # → routed … · toggled paused · fell back <why>
```

In tests use `MockServer.setFrontmost(_:)` and `simulateHotkey(prefer:)`, which returns
the press's single `MockHotkeyOutcome`; inject `MockBehaviour.wakeOpener` so tests never
open real URLs.

## Threading model

* `UnivocalClient` is an `actor`. All of its methods are `async`; call them from any task.
* Transport I/O runs on private dispatch queues (`NWConnection` for the Unix
  socket, `URLSession` for the WebSocket). Inbound messages are processed in
  order on the actor. Nothing touches the main thread.
* `ReadingSession` is a `Sendable` final class; its control methods hop to the
  actor. `events` is a single-consumer `AsyncStream` with unbounded buffering
  (the server already coalesces word events under backpressure) — consume it in
  one task and hop to the MainActor yourself.
* No auto-reconnect: when the connection drops, a live session gets
  `.error(code: .disconnected)` then `.ended(.error)`, the state becomes
  `.disconnected` and `lastError` is set. The next `read()` reconnects.
* `disconnect()` ends a live session locally with `.ended(.stopped, by: nil)`.

## Transports

1. **Unix domain socket** at the path in `<ConnectDir>/connect.json`
   (`NWConnection(to: .unix(path:), using: .tcp)`), NDJSON framing.
2. **Loopback WebSocket** (`URLSessionWebSocketTask`) when the discovery file
   advertises `ws` and the socket is unreachable — for sandboxed hosts. One JSON
   object per text frame; no `Origin` header is sent; non-loopback URLs are
   refused. Tested against an in-process `NWListener` WebSocket bridge to the
   mock server; **not yet tested against Univocal**, which does not serve it yet.

## Testing against the mock

`Sources/UnivocalMock` is a conformant server for tests and manual QA, and
`univocal-mock` its CLI (POSIX `socket/bind/listen` + `DispatchSource`, not
`NWListener`: it needs the fd for `getpeereid` and for exact outbound-buffer
accounting):

```sh
swift run univocal-mock serve --dir /tmp/uc-qa --consent prompt --wpm 200 --verbose
UNIVOCAL_CONNECT_DIR=/tmp/uc-qa swift run univocal-mock client --dir /tmp/uc-qa --text "Hello there."
swift run univocal-mock check --dir "$HOME/Library/Application Support/Univocal Dev/Connect"   # probe a live server
swift run univocal-mock check --hotkey --dir …   # also S37/S43: press ⌥⇧R with the terminal frontmost
swift run univocal-mock ctl --dir /tmp/uc-qa status   # drive a running serve without its stdin
```

`serve` also accepts `--answer-ms`, `--accepted-ms`, `--wake-ms`,
`--wake-opener open|print|fail` and `--no-hotkey-routing`; `client` accepts
`--hotkey-target`, `--accept-first`, `--answer-delay-ms N`, `--decline REASON`,
`--quiet` (exit 3 when not authorised), `--wake URL` and `--token-file F`. Run
`univocal-mock --help` for the full list. The serve log never contains text.

## Extraction

This folder is designed to become its own SwiftPM repository,
`univocal-connect-swift`. It has no dependency on the host app; the only coupling
is the target entry in the host's `Package.swift`. To extract: copy
`Sources/UnivocalClient`, `Sources/UnivocalMock`, `Sources/UnivocalMockCLI` and
`Tests/UnivocalClientTests` with the three targets, two libraries and one
executable from `Package.swift`, plus `docs/univocal-protocol`.
