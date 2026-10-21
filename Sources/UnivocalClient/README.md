# UnivocalClient — Univocal Connect for Swift

<!-- SPDX-License-Identifier: MIT · Copyright (c) 2026 NarNar Labs -->

A small Swift SDK for **Univocal Connect v1**: ask [Univocal](https://univocalapp.com)
to read text aloud and receive word- and sentence-level progress to highlight in
your own UI. The protocol is specified in
[`docs/univocal-protocol/SPEC.md`](../../docs/univocal-protocol/SPEC.md); this
package is its reference client.

* macOS 13+, Swift 5.9+, strict-concurrency clean, every public type `Sendable`.
* Imports only Foundation, Network, Security and `os` (plus AppKit, behind
  `#if canImport(AppKit)`, in `UnivocalAvailability.swift` for LaunchServices).
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
`kSecClassGenericPassword`, service `com.univocal.connect`, account = Univocal's
bundle id. `InMemoryTokenStore` is for tests, previews and CLIs.

### Environment (QA only — never set in a shipped app)

| Variable | Effect |
|---|---|
| `UNIVOCAL_CONNECT_DIR` | Overrides `<ConnectDir>` (point it at a `univocal-mock` directory). |
| `UNIVOCAL_BUNDLE_ID` | Overrides the server bundle id (`com.univocal.app.dev` for dev builds). |

Tests should not mutate the process environment: use
`UnivocalConfiguration(client:environment:)` and set `connectDirectory`,
`tokenStore`, `appLocator` and `launcher` directly.

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
```

## Extraction

This folder is designed to become its own SwiftPM repository,
`univocal-connect-swift`. It has no dependency on the host app; the only coupling
is the target entry in the host's `Package.swift`. To extract: copy
`Sources/UnivocalClient`, `Sources/UnivocalMock`, `Sources/UnivocalMockCLI` and
`Tests/UnivocalClientTests` with the three targets, two libraries and one
executable from `Package.swift`, plus `docs/univocal-protocol`.
