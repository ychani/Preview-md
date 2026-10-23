# Univocal Connect — Protocol Specification, version 1

<!--
SPDX-License-Identifier: MIT
Copyright (c) 2026 NarNar Labs. This specification is released under the MIT
licence (see LICENSE in this folder) so that any application may implement it.
Univocal itself is a separate, proprietary product; this document only governs
the wire protocol between Univocal and other applications on the same Mac.
-->

**Status:** Draft 2 (2026-10-22; Draft 1 was 2026-10-21). **Protocol identifier:** `univocal-connect`. **Major version:** `1`.

Draft 2 adds **hotkey routing** (§5.11, §16) as additive capabilities
`hotkey-routing` (server) / `hotkey-target` (client), the optional
`read.requestId` and `hello.quiet` fields, and error code `unknownRequest`. No
existing message changed; Draft 1 peers interoperate unchanged.

The key words MUST, MUST NOT, REQUIRED, SHALL, SHOULD, SHOULD NOT, RECOMMENDED,
MAY and OPTIONAL are to be interpreted as described in RFC 2119.

## 1. Purpose and split of responsibilities

Univocal Connect lets any application on a Mac (the **client**) ask Univocal (the
**server**) to read a piece of text aloud and receive word- and sentence-level
progress so the client can highlight the text in its own user interface.

The split is deliberate and fixed:

* **Univocal speaks and owns playback.** It synthesises, plays audio, keeps the
  playback clock, applies the user's voice and rate, and maps what was actually
  spoken back onto the text the client sent.
* **Clients highlight.** A client never receives audio. It receives offsets into
  the text it sent, and paints them however it likes.

Everything in this document happens on one machine. Text never leaves the Mac.

## 2. Terminology

| Term | Meaning |
|---|---|
| Server | The Univocal app (bundle id `com.univocal.app`; dev builds `com.univocal.app.dev`). |
| Client | Any process that connects: native app, Electron plugin, CLI, or a browser via the native-messaging host (§9.4). |
| Connection | One transport connection. A client MAY hold several; each is independent. |
| Grant | The user's recorded approval for one client identity, represented to the client as a **token**. |
| Session | One reading of one text, identified by a client-chosen `sessionId`, owned by the connection that created it. |
| Owner | The connection that created the active session. |
| Offset | A UTF-16 code-unit index into the session text (§7). |
| Frontmost app | `NSWorkspace.shared.frontmostApplication` at the instant the server's read hotkey fires (§16). |
| Hotkey request | A server-initiated `readRequest` (§5.11) asking a client to read in place of the server's own panel; identified by a server-chosen `requestId`. |
| Target | A connected, granted connection that announced `hotkey-target` and resolves (§16.3) to the frontmost app. |

## 3. Transports and framing

### 3.1 Primary transport: Unix domain socket (REQUIRED for servers)

The server MUST listen on a stream Unix domain socket at

```
<ConnectDir>/connect.sock
```

where `<ConnectDir>` is `~/Library/Application Support/Univocal/Connect` for the
release build and `~/Library/Application Support/Univocal Dev/Connect` for the dev
build. Implementations MUST honour the environment variable `UNIVOCAL_CONNECT_DIR`
as an override of `<ConnectDir>` (used by tests and mock servers so QA never
touches the real location).

* The server MUST create `<ConnectDir>` with mode `0700` and the socket with mode
  `0600`, and MUST unlink a stale socket file before binding.
* If the socket path would exceed 103 bytes (the `sun_path` limit), the server
  MUST bind elsewhere under a `0700` directory it owns and advertise the real
  path in the discovery file (§4). Clients MUST therefore prefer the path in the
  discovery file over the well-known path.
* Framing is **NDJSON**: each message is one JSON object (RFC 8259) encoded as
  UTF-8 followed by a single `\n` (0x0A). A message MUST NOT contain a raw
  newline; JSON string escapes (`\n`) are of course allowed. Receivers MUST
  tolerate `\r\n`.
* Maximum frame size: servers MUST accept frames of at least 1 MiB
  (1,048,576 bytes including the newline) and MUST close the connection with
  error `protocolError` (fatal) on a frame larger than the advertised
  `limits.maxFrameBytes` (§5.2).
* The server MUST verify the peer with `getpeereid(2)` and MUST close any
  connection whose peer uid differs from its own.
* The server SHOULD resolve the peer's code identity (§6.2) using the peer's
  audit token (`getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)` →
  `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)`), falling back to
  `LOCAL_PEERPID` + `kSecGuestAttributePid`.

### 3.2 Secondary transport: loopback WebSocket (OPTIONAL for servers)

Sandboxed apps cannot connect to an arbitrary Unix socket without temporary-
exception entitlements, so a server MAY additionally listen on a WebSocket
(RFC 6455) at `ws://127.0.0.1:<port>/connect`, with an ephemeral `<port>`
advertised in the discovery file. Servers that offer it MUST advertise capability
`ws-transport`.

* One JSON object per **text** frame. Binary frames MUST be refused (close code
  1003). No trailing newline is required; receivers MUST tolerate one.
* The server MUST refuse the HTTP upgrade (HTTP 403) when an `Origin` header is
  present unless its value is on an explicit server-side allow-list, which is
  empty by default. Browser pages always send `Origin`, so they are refused.
  Electron renderers also send `Origin`; Electron and Node clients MUST use the
  Unix socket from the main/node process instead (§9.3).
* The server cannot identify the peer process on TCP. On this transport the
  `hello.token` is REQUIRED for any operation beyond the consent flow, and a
  grant issued over it is recorded as *unverified* (§6.2).
* The server MUST bind to `127.0.0.1` only (not `0.0.0.0`, not `::1` unless also
  loopback-only).

### 3.3 Transport-independent rules

* Messages are JSON objects with a string field `type`. All other fields are
  defined per message in §5.
* A receiver MUST ignore unknown fields. A **client** MUST ignore messages of
  unknown `type`. A **server** receiving an unknown `type` MUST reply with
  `error{code:"unknownType"}` (non-fatal) if the message carried an `id`, and
  otherwise ignore it.
* Numbers are JSON numbers; offsets and sizes are non-negative integers; rates
  are finite positive numbers.
* The server MUST close the connection on malformed JSON (`protocolError`,
  fatal) and MUST NOT attempt to resynchronise.
* A client MAY send `ping` at any time; the server MUST answer `pong`. Servers
  MAY also send `ping`. Neither side is REQUIRED to time out an idle
  connection.

## 4. Discovery and launch

### 4.1 Installed?

Clients detect installation through LaunchServices
(`NSWorkspace.urlForApplication(withBundleIdentifier: "com.univocal.app")`, or
`mdfind "kMDItemCFBundleIdentifier == 'com.univocal.app'"` / `open -b` from a
CLI). If absent, the client SHOULD offer a "Get Univocal" link
(`https://univocalapp.com`) and stop here.

### 4.2 Running? — the discovery file

While its listener is up, the server MUST maintain `<ConnectDir>/connect.json`
(mode `0600`, written atomically via rename):

```json
{
  "protocol": "univocal-connect",
  "versions": [1],
  "socket": "/Users/me/Library/Application Support/Univocal/Connect/connect.sock",
  "ws": { "url": "ws://127.0.0.1:52133/connect" },
  "pid": 4242,
  "server": { "name": "Univocal", "version": "0.5.0", "bundleId": "com.univocal.app" },
  "startedAt": "2026-10-21T18:02:11Z"
}
```

`ws` is OPTIONAL. The server MUST remove the file on orderly shutdown. A file
whose `pid` is not alive (`kill(pid, 0)` fails with `ESRCH`) is stale; clients
MUST treat it as "not running". A successful connect followed by a valid
`welcome` or consent message is the only proof the server is up.

### 4.3 Launch on demand

If installed but not running, a client MAY launch the server:

* Native: `NSWorkspace.openApplication(at:configuration:)` with `activates =
  false` and arguments `["--connect"]`.
* CLI / scripts: `open -g -b com.univocal.app --args --connect`.
* URL: `univocal://connect` (the server registers the `univocal` scheme).

`--connect` and `univocal://connect` mean "start, stay in the background, bring
up the listener". The server MUST start the listener before any first-run or
engine work, so the handshake completes even while the speech engine is cold;
cold-start latency is surfaced through `state{loading}` (§5.7).

After launching, the client SHOULD retry connecting with backoff (e.g. 100 ms
doubling to 1 s) for up to 10 s, then report "Univocal did not start".

## 5. Messages

Field tables: **R** = required, **O** = optional. Direction `C→S` client to
server, `S→C` server to client.

### 5.1 `hello` (C→S) — REQUIRED first message

```json
{ "type": "hello", "protocol": "univocal-connect", "versions": [1],
  "client": { "id": "com.narnarlabs.previewmd", "name": "PreviewMD",
              "version": "0.5.0", "bundleId": "com.narnarlabs.previewmd" },
  "capabilities": ["word-events", "sentence-events"],
  "token": "uc1_Z3Vlc3Mgd2hhdCBpIGFtIG5vdCByZWFs" }
```

| Field | | Notes |
|---|---|---|
| `protocol` | R | MUST be `"univocal-connect"`. |
| `versions` | R | Major versions the client speaks, descending preference. |
| `client.id` | R | Reverse-DNS, stable across versions. Grants are keyed on it. 1–128 chars `[A-Za-z0-9._-]`. |
| `client.name` | R | Human-readable, shown in the consent prompt (≤ 64 chars). |
| `client.version` | R | Free-form. |
| `client.bundleId` | O | Informational; the server trusts the code identity it resolves itself (§6.2), never this field. |
| `capabilities` | O | Client capability strings (§11). |
| `token` | O | A previously granted token. Omit on first contact. |
| `quiet` | O | `true`: "connect only if already authorised" — if consent would be needed the server MUST NOT prompt and MUST reply `consentDenied{reason:"quiet"}` then close (§16.9). Default `false`. |
| `wakeRequestId` | O | The `requestId` from a wake URL (§16.5); tells the server which pending hotkey request this connection is answering. |

The first message on a connection MUST be `hello`. Anything else is a fatal
`protocolError`. If no common major version exists the server replies
`error{code:"unsupportedVersion", versions:[...]}` (fatal).

### 5.2 `welcome` (S→C)

```json
{ "type": "welcome", "version": 1,
  "server": { "name": "Univocal", "version": "0.5.0", "bundleId": "com.univocal.app" },
  "capabilities": ["word-events", "sentence-events", "seek", "rate", "chunking", "voices", "panel"],
  "limits": { "maxFrameBytes": 1048576, "maxTextBytes": 8388608,
              "rate": { "min": 0.25, "max": 4.0 } },
  "grant": { "clientId": "com.narnarlabs.previewmd", "identity": "ABCDE12345:com.narnarlabs.previewmd" } }
```

Sent once the connection is authorised. `limits.maxTextBytes` is the total UTF-8
size of one session's text across all chunks. `limits.rate` bounds `setRate`.
`grant.identity` echoes how the server identified the client (§6.2) so clients
can show it in their own settings.

### 5.3 Consent flow (S→C): `consentPending`, `consentGranted`, `consentDenied`

When `hello` carries no token, an unknown/revoked token, or a token whose bound
identity does not match the connecting process:

```json
{ "type": "consentPending", "requestId": "c7f1…", "timeoutSeconds": 120 }
```

The server shows its own approval UI naming the app (§6.1). Then either

```json
{ "type": "consentGranted", "requestId": "c7f1…", "token": "uc1_…" }
```

immediately followed by `welcome` on the same connection (the client MUST NOT
re-send `hello`), or

```json
{ "type": "consentDenied", "requestId": "c7f1…", "reason": "user" | "timeout" | "disabled" | "rateLimited" | "quiet" }
```

followed by the server closing the connection. `reason:"quiet"` is only sent in
answer to `hello{quiet:true}` (§16.9): no prompt was shown; the client SHOULD
discard the token it presented (it is no longer valid) and MUST NOT retry
without a user action. The client MUST store a granted
token securely (Keychain on macOS) keyed by the server's `bundleId`, and present
it in future `hello`s. A token that is unknown or revoked yields
`consentPending` again (the server re-prompts), unless the grant was revoked
less than 10 minutes ago, in which case the server MUST reply
`error{code:"unauthorized", reason:"revoked"}` (fatal) instead, so a client
cannot nag the user immediately after being revoked.

While waiting, the client SHOULD show "Waiting for approval in Univocal…".

### 5.4 `read` (C→S) — start a session

```json
{ "type": "read", "id": 7, "sessionId": "8E4C…",
  "text": "Revenue reached $5B.\n\nNext year looks brighter.",
  "lang": "en", "voice": null, "rate": 1.25, "startOffset": 0,
  "preempt": true, "ui": "none", "more": false,
  "meta": { "title": "Q3 notes.md" } }
```

| Field | | Notes |
|---|---|---|
| `id` | O | Echoed in `ok`/`error`. Any JSON string or integer. |
| `sessionId` | R | Client-chosen, unique per connection; UUID RECOMMENDED. |
| `text` | R | The text (or its first chunk, §8). MAY be empty only when `more` is true. |
| `lang` | O | BCP-47 hint. Server MAY auto-detect; MUST NOT fail on an unknown tag. |
| `voice` | O | A voice id from `voices` (§5.10). `null`/absent = user's default. |
| `rate` | O | Initial rate, clamped to `limits.rate`. Absent = user's default. |
| `startOffset` | O | Offset to begin at (default 0). Server starts at the beginning of the sentence containing it. |
| `preempt` | O | Default `true`: end any active session (`ended{reason:"preempted"}`) and take over. `false`: fail with `busy` if a session is active anywhere. |
| `ui` | O | `"none"` (default): the server shows no reading panel, only its menu-bar state. `"panel"`: server also shows its own panel (capability `panel`). |
| `more` | O | `true` if `append` chunks follow (§8). |
| `meta.title` | O | Shown in the server's menu-bar/panel UI. Never logged. |
| `requestId` | O | Answers the server's `readRequest` with that id (§5.11, §16). A `read` whose `requestId` is unknown or expired is **not started**: the server replies `error{code:"unknownRequest"}` (non-fatal) and nothing else changes. |

On acceptance the server sends `ok{id, sessionId}` then `state{loading}`. Any
other active session on **any** connection ends first (§6.4). A `read` that
answers a hotkey request behaves exactly like any other `read` once accepted;
`preempt` is implied `true` for it (the hotkey already ended whatever was
playing, §16.4 step 2).

### 5.5 Session control (C→S): `pause`, `resume`, `stop`, `seek`, `setRate`, `append`

All carry `sessionId` and OPTIONAL `id`. Only the owner may send them; others get
`error{code:"notOwner"}`.

```json
{ "type": "pause",   "id": 8, "sessionId": "8E4C…" }
{ "type": "resume",  "id": 9, "sessionId": "8E4C…" }
{ "type": "stop",    "id": 10, "sessionId": "8E4C…" }
{ "type": "seek",    "id": 11, "sessionId": "8E4C…", "offset": 2210 }
{ "type": "setRate", "id": 12, "sessionId": "8E4C…", "rate": 1.5 }
{ "type": "append",  "id": 13, "sessionId": "8E4C…", "text": "…", "more": false }
```

* `seek.offset` MUST be within `[0, textLength]`; the server moves to the word
  containing the offset (or the next word) and keeps the current play/pause
  state. Out of range → `error{code:"invalidOffset"}`.
* `setRate` is clamped to `limits.rate`; the effective value is reported by a
  `rate` event.
* `stop` ends the session with `ended{reason:"stopped"}`.
* Control messages for an ended or unknown session → `error{code:"noSession"}`.

### 5.6 `ok` (S→C)

```json
{ "type": "ok", "id": 8, "sessionId": "8E4C…" }
```

Sent for every accepted C→S command that carried an `id` — `read`, `append`,
`pause`, `resume`, `stop`, `seek`, `setRate`. `listVoices` and `ping` are
answered by `voices` and `pong` instead, never by `ok`. Commands without `id`
are acknowledged only by their effects.

### 5.7 Session events (S→C) — owner only

```json
{ "type": "state",    "sessionId": "8E4C…", "state": "loading", "detail": "Starting speech engine…" }
{ "type": "state",    "sessionId": "8E4C…", "state": "playing" }
{ "type": "state",    "sessionId": "8E4C…", "state": "paused" }
{ "type": "sentence", "sessionId": "8E4C…", "start": 0,  "end": 21 }
{ "type": "word",     "sessionId": "8E4C…", "start": 16, "end": 19 }
{ "type": "progress", "sessionId": "8E4C…", "offset": 19 }
{ "type": "rate",     "sessionId": "8E4C…", "rate": 1.5 }
{ "type": "ended",    "sessionId": "8E4C…", "reason": "finished" }
```

* `state.state` ∈ `loading | playing | paused`. `detail` is OPTIONAL
  user-presentable text (e.g. engine cold start, model download).
* `sentence` is emitted when a sentence becomes current, **before** its first
  `word`. `word` is emitted when the playback clock enters a word. Both carry
  half-open `[start, end)` offsets into the session text (§7), `start < end`.
* Successive `word` events MAY carry an identical range (one source token
  spoken as several words, e.g. `$5B` → "five billion dollars"); clients SHOULD
  not re-animate an unchanged range.
* `progress` is OPTIONAL (capability `progress`), at most once per second.
* `rate` is sent whenever the effective rate changes, from any source.
* `ended.reason` ∈ `finished | stopped | preempted | error | revoked`.
  `preempted` MAY carry `by: "<other client name or 'Univocal'>"`. `error` MUST
  be preceded by an `error` message with the same `sessionId`. `ended` is the
  last message for a session; the server MUST send nothing further for it.
* A session whose owner disconnects ends silently (no one to notify).

The server MUST emit `word`/`sentence`/`progress` only for text the client sent
and only to the owner.

### 5.8 `error` (S→C)

```json
{ "type": "error", "id": 11, "sessionId": "8E4C…", "code": "invalidOffset",
  "message": "offset 99999 exceeds text length 61", "fatal": false }
```

`id` and `sessionId` are present when applicable. `fatal: true` means the server
closes the connection right after. Codes are in §10.

### 5.9 `ping` / `pong` (both directions)

```json
{ "type": "ping", "id": 1 }   →   { "type": "pong", "id": 1 }
```

### 5.10 `listVoices` (C→S) / `voices` (S→C) — capability `voices`

```json
{ "type": "listVoices", "id": 3 }
{ "type": "voices", "id": 3, "default": "bf_emma",
  "voices": [ { "id": "bf_emma", "name": "Emma", "lang": "en-GB" },
              { "id": "sup:ko:F1", "name": "Korean · F1", "lang": "ko" } ] }
```

### 5.11 Hotkey requests: `readRequest` (S→C), `readAccepted`, `readDecline` (C→S) — capabilities `hotkey-routing` / `hotkey-target`

Sent by the server only to a connection that announced client capability
`hotkey-target`, and only when the server announced `hotkey-routing`. The full
behaviour — when the server sends it, to whom, and what happens otherwise — is
§16; this section is the wire contract.

```json
{ "type": "readRequest", "requestId": "h3a9…", "trigger": "hotkey",
  "prefer": "selection", "answerMs": 300, "acceptedMs": 1500 }
```

| Field | | Notes |
|---|---|---|
| `requestId` | R | Server-chosen, unique per server run; opaque to the client (≤ 64 chars). |
| `trigger` | R | `"hotkey"` in v1. Clients MUST ignore requests with a trigger they do not know. |
| `prefer` | R | `"selection"`: read the selection if there is one, else the document from the visible position. `"document"`: read the document from the visible position even if there is a selection. |
| `answerMs` | R | Milliseconds, measured by the server from the moment it sent this message, within which **some** answer must *arrive*: a `read{requestId}`, a `readAccepted`, or a `readDecline`. Servers MUST use ≥ 300. |
| `acceptedMs` | R | Milliseconds from the same instant within which the `read` must arrive once `readAccepted` was received. Servers MUST use ≥ 1500 and ≥ `answerMs`. |

The client answers with exactly one of:

```json
{ "type": "read", "id": 21, "requestId": "h3a9…", "sessionId": "…", "text": "…", "startOffset": 812, … }
{ "type": "readDecline", "requestId": "h3a9…", "reason": "noContent", "detail": "Edit view" }
```

optionally preceded by

```json
{ "type": "readAccepted", "requestId": "h3a9…" }
```

* **Answer within budget.** "Arrive" means the complete NDJSON frame was received
  by the server before its deadline; the server's `ok` is not part of the
  budget. Clients SHOULD send `readAccepted` immediately on receipt whenever
  the text is not already in hand (asynchronous extraction, a web view round
  trip, a plugin host hop) and then the `read` as soon as it is; the server
  then waits up to `acceptedMs`. A client whose text is cached MAY skip
  `readAccepted` and send `read` directly.
* `readAccepted` and `readDecline` carry no `id` and are never acknowledged
  with `ok`. A stale or unknown `requestId` in either is ignored silently.
  A `read` with a stale/unknown `requestId` gets `error{unknownRequest}` and
  is not started (§5.4).
* `readDecline.reason` ∈ `noContent` (nothing to read: no document, empty
  text) · `busy` (the client cannot read now: a modal, mid-save) · `notFocused`
  (this connection does not own the app's key window / focused tab; §16.4 step
  5 lets the server try another connection of the same app) · `userDisabled`
  (the user turned the feature off in the client) · `other`. `detail` is an
  OPTIONAL, user-neutral string for logs; never document text.
* Once the server has acted on a request — started the client's `read`, fallen
  back, or dropped it — the `requestId` is dead; it is never reused.
* After the `read` is accepted the session is ordinary: `ok`, `state{loading}`,
  events, controls (§5.4–§5.7). `state{loading}` MAY arrive before the client
  has finished any local bookkeeping; clients MUST NOT depend on ordering
  between their own `read` returning and the first `state`.

## 6. Consent, identity, and multi-client policy

### 6.1 Consent

First contact from a client identity MUST produce a prompt in the server's own
UI, naming the app (`client.name`), the resolved identity (§6.2) and what is
granted: "<App> can send text for Univocal to read aloud and will receive
reading progress." Choices: Allow / Don't Allow. The server MUST NOT auto-grant
except in a dedicated test mode (`UNIVOCAL_CONNECT_AUTOGRANT=1`, which the
release build MUST ignore).

* Exactly one prompt is visible at a time; further requests queue. A connection
  MAY have only one pending request. More than 3 consent requests per minute
  from one identity → `consentDenied{reason:"rateLimited"}`.
* Tokens are 32 random bytes, base64url, prefixed `uc1_`. The server stores only
  a SHA-256 hash with the grant record `{clientId, identity, name, createdAt,
  lastUsedAt}`; the plaintext exists only in the `consentGranted` message.
* The user can revoke any grant in Univocal's settings; revocation ends that
  identity's active session with `ended{reason:"revoked"}` and closes its
  connections with `error{code:"unauthorized", reason:"revoked"}` (fatal).
* A global "Allow other apps to use Univocal" switch MAY exist; when off, every
  hello gets `consentDenied{reason:"disabled"}`.

### 6.2 Identity

The server computes an **identity string** per connection:

| Case | Identity | Consent prompt shows |
|---|---|---|
| Signed with a Team ID (Developer ID / App Store / Apple Development) | `<teamId>:<signingIdentifier>` e.g. `ABCDE12345:com.narnarlabs.previewmd` | App name, bundle id, "Verified developer" |
| Signed without Team ID, ad-hoc, or unsigned (dev builds, CLIs, scripts) | `unverified:<client.id>` | App name, "Unverified build" badge |
| WebSocket transport (no peer process) | `unverified:<client.id>` | "Unverified (network)" badge |

A token is bound to `(clientId, identity)`. Presenting a token from a connection
with a different identity MUST be treated as no token (consent is re-requested
and the prompt says a different build is asking). Verified identities MUST NOT
be downgraded: if a grant exists for `ABCDE12345:com.foo` and an `unverified:
com.foo` connects, that is a distinct grant.

### 6.3 Threat model

In scope: other local user accounts (defeated by the `0700` directory, `0600`
socket and uid check); web pages in any browser (defeated by Origin refusal on
the WebSocket, the Unix socket being unreachable from a page, and the
native-messaging host being the only browser path); unsigned processes of the
same user trying to drive Univocal silently (defeated by the consent prompt and
the "Unverified" badge); token theft from a client's storage (bounded by
identity binding for signed clients; unsigned clients are only as safe as the
Keychain ACL). Out of scope: malware running as the same user with code-injection
or debugger rights — nothing on macOS without the App Sandbox can defend
against that, and neither can this protocol.

### 6.4 One session system-wide

Univocal has one audio output, so there is **one active session system-wide**,
across all connections and Univocal's own hotkey reading.

* A `read` with `preempt:true` (default) ends the active session, whoever owns
  it, with `ended{reason:"preempted"}` to that owner, then starts the new one.
* Univocal's own reading (hotkey, panel) preempts Connect sessions the same way
  (`by: "Univocal"`).
* Control is owner-only. Controls operated in Univocal's UI (menu bar, panel if
  shown, media keys) act on the active session and are reported to the owner as
  ordinary `state`/`rate`/`ended` events.
* Non-owners learn nothing about the active session: no events, and `busy` only
  as the answer to their own `preempt:false` read.

## 7. Offsets and text

* All offsets are **UTF-16 code-unit** indices into the session text: the exact
  string obtained by JSON-decoding `read.text` and concatenating subsequent
  `append.text` values in order (§8). Ranges are half-open `[start, end)`.
* The server MUST compute offsets against that string **unmodified**. Any
  normalisation it performs for speech (Unicode NFC, abbreviation expansion,
  `$5B` → "five billion dollars", CRLF, whitespace) MUST be mapped back; a word
  the engine rewrote maps to the source token's range. Spoken material with no
  source counterpart (an announced "code block", a pause) produces no `word`.
* A range MUST NOT split a UTF-16 surrogate pair; servers MUST widen outward to
  the pair boundary. Clients MUST tolerate ranges that cover grapheme clusters
  in full (combining marks, emoji sequences).
* The server MUST treat `\n\n` as a sentence boundary and SHOULD treat a single
  `\n` as one, so block and table-cell text supplied by clients does not run
  together. Clients SHOULD send `\n` line endings (not `\r\n`) so their own
  offsets agree with their UI.
* Language bindings: JavaScript/TypeScript string indices **are** UTF-16 —
  use them directly. Swift: use `String.utf16` /
  `String.Index(utf16Offset:in:)` or `NSString`/`NSRange`, never
  `String.count`. Python: `str` indexes code points — encode to `utf-16-le` and
  divide byte offsets by 2, or maintain a code-point↔code-unit map. Rust:
  `encode_utf16()`.

## 8. Long documents, chunking, backpressure

* One frame carries at most `limits.maxFrameBytes` (≥ 1 MiB). For larger text
  the client sends `read{more:true}` followed by one or more
  `append{sessionId, text, more}`; the last chunk has `more:false`. Offsets
  continue globally (chunk *k* begins at the UTF-16 length of chunks `0..k-1`).
* The total MUST stay under `limits.maxTextBytes` or the server ends the
  session with `error{code:"limitExceeded"}` + `ended{reason:"error"}`.
* The server MAY begin speaking before the final chunk. It MUST NOT synthesise
  the trailing partial sentence of a chunk until the next chunk arrives or
  `more:false` is seen. Clients SHOULD cut chunks at paragraph boundaries.
* If playback reaches the end of received text while `more` is pending, the
  server sends `state{loading, detail:"Waiting for text…"}` and resumes
  automatically when text arrives.
* **Outbound coalescing:** if a connection's unsent outbound buffer exceeds
  256 KiB, the server MUST drop queued `word`, `sentence` and `progress` events
  that are superseded by a newer event of the same type for the same session,
  and MUST NEVER drop `welcome`, consent messages, `ok`, `error`, `state`,
  `rate`, `voices` or `ended`. If the buffer exceeds 4 MiB the server closes the
  connection with `error{code:"slowConsumer", fatal:true}`.
* Inbound: the server MAY reply `error{code:"rateLimited"}` to more than 50
  control messages per second on one connection.

## 9. Client environments

### 9.1 Native macOS, not sandboxed (e.g. PreviewMD)
Unix socket via Network.framework (`NWEndpoint.unix(path:)`) or POSIX. Token in
Keychain (`kSecClassGenericPassword`, service `com.univocal.connect`, account =
server bundle id).

### 9.2 Native macOS, sandboxed
Use the WebSocket transport (needs only `com.apple.security.network.client`).
The sandbox blocks `<ConnectDir>` by default, so to read `connect.json` the
client either ships the read-only entitlement
`com.apple.security.temporary-exception.files.home-relative-path.read-only`
for `/Library/Application Support/Univocal/Connect/` or asks the user once for
the folder and keeps a security-scoped bookmark. Launch-on-demand works from
the sandbox via `NSWorkspace.openApplication`. Tokens go in the client's own
Keychain. The identity is recorded as `unverified:<client.id>` (§6.2).

### 9.3 Electron / Node (Obsidian, VS Code)
Connect from the main/Node context with `net.connect({ path })`. Do not use the
renderer's WebSocket (it carries `Origin` and is refused). Node strings are
UTF-16; offsets map directly onto CodeMirror positions when the editor text is
the session text, or through a DOM text map in reading view. See
`clients/typescript-outline.md`.

### 9.4 Browsers
Web pages MUST NOT be able to reach the server. Univocal ships a native-messaging
host (`com.univocal.connect`) that bridges the extension's stdio port to the
Unix socket and connects with `client.id = "com.univocal.browser.<extensionId>"`.
The host MUST forward messages unchanged except for `hello`, where it overrides
`client` with the extension's identity and attaches the token it stores. The
host is the identity the user approves.

### 9.5 CLIs and scripts
`nc -U "$UNIVOCAL_CONNECT_DIR/connect.sock"` or any socket library;
`client.id` like `sh.example.readcli`; tokens in Keychain via `security` or a
`0600` file under `~/Library/Application Support/<tool>/`.

## 10. Error codes

| code | fatal | When |
|---|---|---|
| `protocolError` | yes | Malformed JSON, oversize frame, first message not `hello`, raw newline. |
| `unsupportedVersion` | yes | No common major version; reply includes `versions`. |
| `unauthorized` | yes | Token revoked (<10 min), identity mismatch after grant removal, grant disabled; `reason` ∈ `revoked`, `identityMismatch`, `disabled`. |
| `unknownType` | no | Unknown `type` with an `id`. |
| `invalidArgument` | no | Missing/ill-typed required field; `field` names it. |
| `sessionExists` | no | `read` reusing a live `sessionId` on this connection. |
| `noSession` | no | Control for an unknown or ended session. |
| `notOwner` | no | Control from a connection that does not own the session. |
| `busy` | no | `read{preempt:false}` while a session is active. |
| `invalidOffset` | no | `seek.offset` or `startOffset` out of range. |
| `limitExceeded` | no* | Text exceeds `maxTextBytes`; session ends (`ended{error}`). |
| `rateLimited` | no | Too many commands or consent requests. |
| `engineUnavailable` | no* | Speech engine cannot start (first-run download incomplete, disk full); session ends. |
| `engineError` | no* | Synthesis failed mid-session; session ends. |
| `slowConsumer` | yes | Outbound buffer over 4 MiB. |
| `unknownRequest` | no | `read.requestId` names no pending hotkey request (never issued, already answered, expired, or routed to another connection). The `read` is not started. |
| `internal` | varies | Anything else; `message` is user-presentable. |

`no*` = the connection stays open but the session ends with `ended{reason:"error"}`.

## 11. Versioning and capabilities

* `versions` in `hello` and `version` in `welcome` negotiate the **major**
  version. A major bump means an incompatible change to an existing message.
* Additive features are announced as **capability strings** in `welcome` and
  `hello`. Servers MUST NOT send events the client did not request where a
  capability is client-gated (`word-events`, `sentence-events`, `progress`);
  clients MUST NOT send messages for capabilities the server did not announce.
* v1 server capabilities: `word-events`, `sentence-events`, `progress`, `seek`,
  `rate`, `chunking`, `voices`, `panel`, `ws-transport`, `hotkey-routing`
  (Draft 2: the server routes its read hotkey to clients, §16).
  v1 client capabilities: `word-events`, `sentence-events`, `progress`,
  `hotkey-target` (Draft 2: this connection answers `readRequest`, §16).
* A server MUST NOT send `readRequest` to a connection that did not announce
  `hotkey-target`; a client MUST NOT send `readAccepted`/`readDecline` or
  `read.requestId` to a server that did not announce `hotkey-routing`
  (there is nothing to answer).
* Unknown fields and unknown message types are ignored as in §3.3, so minor
  additions never break older peers.
* Deprecation: a message or field removed in version *N+1* MUST keep working in
  servers for at least 12 months after *N+1* ships, with servers continuing to
  accept `versions:[N]`.

## 12. Session state machine

```
                read (ok)            first audio
   (none) ───────────────▶ loading ──────────────▶ playing ◀──────┐
                              │                      │  pause      │ resume
                              │ seek/append/setRate  ▼             │
                              │ allowed              paused ───────┘
                              │                      │
                              ▼  stop / finished / preempted / error / revoked
                            ended  (terminal; `ended` is the last message)
```

* `loading` may recur mid-session (engine restart, waiting for `append`).
* `seek`, `setRate`, `append`, `pause`, `resume` are accepted in `loading`,
  `playing` and `paused`; `pause` in `paused` and `resume` in `playing` are
  no-ops that still get `ok`.
* Owner disconnect from any non-terminal state → session ends, no messages.

Hotkey requests (§16) have their own small lifecycle on the server, *before* a
session exists:

```
 hotkey ──▶ pending ──readAccepted──▶ accepted ──read{requestId}──▶ (session: loading …)
              │  │                       │
              │  └── read{requestId} ────┘──────────────────────────▶ (session: loading …)
              │
              ├── readDecline{notFocused} ──▶ pending (next connection of the same app, if any)
              ├── readDecline{other reason} / answerMs or acceptedMs elapsed / connection closed
              │                                                     ▶ fallback (server reads in its panel)
              └── nothing to route to (no target, no declaration, wake failed) ▶ fallback
```

A `read{requestId}` arriving in any state other than `pending`/`accepted` for
that id → `error{unknownRequest}`, not started.

## 13. Logging and privacy

* The server MUST NOT log text content, `meta.title`, or offsets together with
  text. It MAY log `sessionId`, client ids, identities, text **lengths**, event
  counts and timings.
* The server MUST NOT persist session text beyond what synthesis needs and
  MUST delete synthesised audio for a session when it ends.
* The server MUST store token hashes only (§6.1).
* Clients SHOULD not log received offsets alongside document text at levels
  that ship to users.

## 14. Fallback ladder for clients

1. **Native integration** — this protocol: in-place highlight in the client.
2. **Univocal's own panel** — client puts text on the clipboard or selection
   and triggers Univocal (hotkey or `open -b com.univocal.app --args --text …`);
   Univocal highlights in its floating panel, not in the client.
3. **AX overlay** — only where the target publishes `AXBoundsForRange`
   (browsers yes; Electron and Claude.app measured no). Not part of Connect.
4. **Clipboard** — user copies, Univocal reads.

A client that implements (1) SHOULD fall back to (2) when Univocal is installed
but the user has denied consent, and to a "Get Univocal" link when it is not
installed.

## 15. End-to-end transcript (Unix socket, NDJSON)

PreviewMD reads a two-paragraph document; the user pauses, resumes, and
Univocal's hotkey preempts near the end. `→` is client to server, `←` server to
client.

```
→ {"type":"hello","protocol":"univocal-connect","versions":[1],"client":{"id":"com.narnarlabs.previewmd","name":"PreviewMD","version":"0.5.0","bundleId":"com.narnarlabs.previewmd"},"capabilities":["word-events","sentence-events"]}
← {"type":"consentPending","requestId":"a1","timeoutSeconds":120}
   (user clicks Allow in Univocal)
← {"type":"consentGranted","requestId":"a1","token":"uc1_9mXk…"}
← {"type":"welcome","version":1,"server":{"name":"Univocal","version":"0.5.0","bundleId":"com.univocal.app"},"capabilities":["word-events","sentence-events","seek","rate","chunking","voices","panel"],"limits":{"maxFrameBytes":1048576,"maxTextBytes":8388608,"rate":{"min":0.25,"max":4}},"grant":{"clientId":"com.narnarlabs.previewmd","identity":"unverified:com.narnarlabs.previewmd"}}
→ {"type":"read","id":1,"sessionId":"S1","text":"Revenue reached $5B.\n\nNext year looks brighter.","lang":"en","meta":{"title":"Q3.md"}}
← {"type":"ok","id":1,"sessionId":"S1"}
← {"type":"state","sessionId":"S1","state":"loading","detail":"Starting speech engine…"}
← {"type":"state","sessionId":"S1","state":"playing"}
← {"type":"sentence","sessionId":"S1","start":0,"end":20}
← {"type":"word","sessionId":"S1","start":0,"end":7}
← {"type":"word","sessionId":"S1","start":8,"end":15}
← {"type":"word","sessionId":"S1","start":16,"end":19}      ("five")
← {"type":"word","sessionId":"S1","start":16,"end":19}      ("billion")
← {"type":"word","sessionId":"S1","start":16,"end":19}      ("dollars")
→ {"type":"pause","id":2,"sessionId":"S1"}
← {"type":"ok","id":2,"sessionId":"S1"}
← {"type":"state","sessionId":"S1","state":"paused"}
→ {"type":"resume","id":3,"sessionId":"S1"}
← {"type":"ok","id":3,"sessionId":"S1"}
← {"type":"state","sessionId":"S1","state":"playing"}
← {"type":"sentence","sessionId":"S1","start":22,"end":47}
← {"type":"word","sessionId":"S1","start":22,"end":26}
← {"type":"word","sessionId":"S1","start":27,"end":31}
   (user presses ⌥⇧R in another app; Univocal reads the selection)
← {"type":"ended","sessionId":"S1","reason":"preempted","by":"Univocal"}
→ {"type":"ping","id":4}
← {"type":"pong","id":4}
```

Offsets check: `"Revenue reached $5B."` is 20 UTF-16 units → sentence `[0,20)`;
`$5B` is `[16,19)`; `\n\n` occupies `[20,22)`; the second sentence starts at 22.

### 15.1 Hotkey routing transcript (§16)

PreviewMD is frontmost and connected at launch with `hotkey-target`; the user
presses ⌥⇧R twice (start, then pause) and a third time after switching to an
app without Connect support.

```
→ {"type":"hello","protocol":"univocal-connect","versions":[1],"client":{"id":"com.narnarlabs.previewmd","name":"PreviewMD","version":"0.5.0","bundleId":"com.narnarlabs.previewmd"},"capabilities":["word-events","sentence-events","hotkey-target"],"token":"uc1_9mXk…","quiet":true}
← {"type":"welcome","version":1,"server":{…},"capabilities":["word-events","sentence-events","seek","rate","chunking","voices","panel","hotkey-routing"],"limits":{…},"grant":{…}}
   (user presses ⌥⇧R with a PreviewMD window frontmost; Univocal resolves the peer to PreviewMD)
← {"type":"readRequest","requestId":"h1","trigger":"hotkey","prefer":"selection","answerMs":300,"acceptedMs":1500}
→ {"type":"readAccepted","requestId":"h1"}                       (text comes from a web view: buy time)
→ {"type":"read","id":5,"requestId":"h1","sessionId":"S2","text":"…full document…","startOffset":812,"meta":{"title":"Q3.md"}}
← {"type":"ok","id":5,"sessionId":"S2"}
← {"type":"state","sessionId":"S2","state":"loading"}
← {"type":"state","sessionId":"S2","state":"playing"}
← {"type":"sentence","sessionId":"S2","start":812,"end":871}
← {"type":"word","sessionId":"S2","start":812,"end":816}
   (user presses ⌥⇧R again, PreviewMD still frontmost: same owner → toggle, no readRequest)
← {"type":"state","sessionId":"S2","state":"paused"}
   (user switches to an app without a declaration or connection and presses ⌥⇧R: fallback)
← {"type":"ended","sessionId":"S2","reason":"preempted","by":"Univocal"}
```

## 16. Hotkey routing (capabilities `hotkey-routing` / `hotkey-target`)

### 16.1 What it is

Univocal's read hotkey (⌥⇧R by default) today captures the selection of
whatever app is frontmost and reads it in Univocal's own panel. With hotkey
routing, **the same keystroke reads inside the frontmost app** when that app
is a Connect client: Univocal sends it a `readRequest` (§5.11), the client
answers with a `read`, and the client highlights as in any Connect session.
The user learns one shortcut; it works everywhere; the panel remains the
fallback. A server that implements this section MUST announce
`hotkey-routing`; a client that wants to receive requests MUST announce
`hotkey-target` on the connection that will answer them.

Everything in this section is additive. A Draft 1 client never sees a
`readRequest` (it did not announce `hotkey-target`), and a Draft 1 server never
receives `readAccepted`/`readDecline` (the client saw no `hotkey-routing`).

### 16.2 Frontmost-app detection

On the hotkey the server MUST capture `NSWorkspace.shared.frontmostApplication`
**synchronously on the main thread, before any other work** (its
`processIdentifier`, `bundleIdentifier`, `bundleURL`). A global hotkey
implemented with a CGEvent tap or Carbon hotkey does not change focus, so this
is the app the user is looking at. The capture MUST happen before the server
captures the selection (which may simulate ⌘C) and before it shows or moves any
window of its own. If the frontmost app is the server itself (its panel or
settings), routing is skipped (§16.11).

### 16.3 Process → app resolution

The server knows each connection's **peer pid** (`getsockopt(SOL_LOCAL,
LOCAL_PEERPID)`, or the audit token's pid). The peer is often *not* the app
process: Electron renderers and helpers, a plugin's spawned helper, and the
browser native-messaging host are child processes. A connection **resolves to**
the frontmost app when either test passes, evaluated in this order:

1. **Ancestry.** Walk the peer's parent chain: `pid → ppid` via
   `proc_pidinfo(pid, PROC_PIDTBSDINFO, …).pbi_ppid` (or
   `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)` →
   `kinfo_proc.kp_eproc.e_ppid`), at most 16 hops, stopping at pid 1
   (launchd) or pid 0. If any pid on the chain (including the peer itself)
   equals the frontmost app's pid, the connection resolves.
2. **Bundle containment.** If the peer's executable path (`proc_pidpath`) or
   that of any process on the chain lies inside the frontmost app's
   `bundleURL` (path-prefix test after standardising both; Electron helpers
   live in `Contents/Frameworks/*.app`), the connection resolves. This covers
   a child reparented to launchd after an intermediate parent exited.

Servers MUST NOT use `responsibility_get_pid_responsible_for_pid`
(libquarantine): it is private SPI, not permitted in a notarised app and
subject to change. The public walk above gives the same answer for every case
this spec cares about.

Security: a process cannot alter its own `ppid` or executable path, so an
unrelated app cannot claim to be the frontmost one. Any process the frontmost
app *spawns* does inherit its ancestry and could answer a request on its
behalf; that is acceptable because what the user consented to is the
**connection's own identity** (§6.2), not the frontmost app's, and the request
goes only to connections the user already granted. The frontmost app's bundle
id is never trusted from `hello.client.bundleId`; it comes from NSWorkspace.

### 16.4 Routing algorithm

On every hotkey press the server MUST run exactly these steps, in order. The
press MUST always result in exactly one of: a toggle, one client reading, or
the server's own fallback read. A hotkey press never does nothing silently
(the only "nothing" is the existing beep when the fallback finds no text).

1. **Capture** the frontmost app `F` (§16.2). If `F` is the server, go to 6.
   If there is no frontmost app, end any active session (`preempted`, `by:"Univocal"`)
   and go to 6.
2. **Toggle check** (§16.7): if a session is active (`loading`, `playing` or
   `paused`) and its owner connection resolves to `F`, pause it if playing or
   loading, resume it if paused, and **stop**. Otherwise end the active
   session with `ended{reason:"preempted", by:"Univocal"}` (whoever owns it,
   §6.4) and continue.
3. **Candidates:** all connections that are in the `ready` state (past
   `welcome`), announced `hotkey-target`, and resolve to `F` (§16.3). Order
   them by **most recent inbound message first** (any message, including
   `pong`), ties broken by newest connection. Recommended: one Connect
   connection per app for hotkey purposes; multiple connections are only a
   tie-break problem, not an error.
4. **No candidates:** if `F` is not connected, try the wake path (§16.5). If
   `F` has no declaration or the wake fails, go to 6.
5. **Ask** the first candidate: send `readRequest{requestId, trigger:"hotkey",
   prefer, answerMs, acceptedMs}`; `prefer` is `"selection"` unless the user
   set a server preference for `"document"`. Start the `answerMs` timer.
   * `read{requestId}` arrives in time → accept it as the session (`ok`,
     `state{loading}`…) and **stop**. The request is now dead.
   * `readAccepted{requestId}` arrives in time → extend the deadline to
     `acceptedMs` from the original send; then `read` in time → as above.
   * `readDecline{reason:"notFocused"}` → remove this candidate; if another
     candidate remains and the **total** elapsed since step 1 is under
     `acceptedMs`, repeat step 5 with the next one (a fresh `requestId`).
     Otherwise go to 6.
   * Any other `readDecline`, the connection closing, or the deadline
     elapsing → go to 6. A `read` for that id that arrives later is answered
     `error{unknownRequest}` and not started.
6. **Fallback:** the server's Draft 1 behaviour — read the frontmost app's
   selection (or clipboard) in Univocal's own panel; beep if there is nothing.

Pending requests MUST be dropped (and the fallback skipped) if a newer hotkey
press arrives first: the newest press wins, and an in-flight `read` for the
older id gets `unknownRequest`.

### 16.5 Apps that are running but not connected: declaration and wake

The frontmost app is running by definition. "Not connected" means it has no
Connect connection right now (it connects lazily, or it was not granted yet).
Such an app can still receive the hotkey if it declares support in its
`Info.plist` (Appendix B):

| Key (inside dict `UnivocalConnect`) | Type | Meaning |
|---|---|---|
| `Versions` | array of integer | Protocol major versions the app speaks. REQUIRED. |
| `HotkeyTarget` | boolean | `true`: the app answers `readRequest` once connected. REQUIRED for this path. |
| `WakeURLScheme` | string | A URL scheme registered in the same bundle's `CFBundleURLTypes`. REQUIRED for this path. |

The server reads `F.bundleURL/Contents/Info.plist` (`Bundle(url:)?.infoDictionary`
or `CFBundleCopyInfoDictionaryForURL`) at hotkey time (cache per bundle URL
and modification date). If `UnivocalConnect` is present, `Versions` shares a
major version with the server, `HotkeyTarget` is `true` and `WakeURLScheme` is
set, the server:

1. Creates the pending request (`requestId`) **before** waking.
2. **Checks the handler before opening.** The server MUST call
   `NSWorkspace.shared.urlForApplication(toOpen: url)` and MUST NOT open the
   URL unless it returns an app whose bundle identifier equals `F`'s. If it
   returns nothing — no app registered for the scheme, e.g. a build that
   LaunchServices never registered, such as one run from `/tmp` — macOS
   would show the user "There is no application set to open the URL…";
   if it returns another app, that app would launch or activate. In both
   cases the server drops the pending request and falls back **silently**
   (§16.8), with no dialog of its own.
3. Opens the wake URL

   ```
   <WakeURLScheme>://univocal-connect/read?requestId=<requestId>&v=1
   ```

   with `F` itself — `NSWorkspace.shared.open([url], withApplicationAt:
   F.bundleURL, configuration:)` — so that with two copies of one app (a
   release and a dev build, same bundle id) the frontmost copy is the one
   woken, where `configuration.activates = false` (the app is already
   frontmost; this avoids focus churn and a Dock bounce) and
   `addsToRecentItems = false`. `v` is the protocol major version
   the server will speak. Clients MUST ignore unknown query items. The URL
   path is fixed to `univocal-connect/read` so apps can route it without
   parsing anything else.
4. Waits up to the **wake budget** (§16.6) for a connection whose `hello`
   carries `wakeRequestId == requestId` **and** resolves to `F` (§16.3). Both
   conditions are REQUIRED: the echo alone must not let a different process
   claim the request. A `hello` with a `wakeRequestId` that matches no
   pending request is treated as an ordinary `hello`.
5. If that connection needs consent, the server prompts as usual and the
   pending request **survives the prompt**: the wake budget is suspended
   while `consentPending` is outstanding and resumes on `consentGranted`.
   `consentDenied` ends the request → fallback.
6. Right after `welcome` on that connection, the server sends the pending
   `readRequest` and continues at §16.4 step 5 with fresh `answerMs`/`acceptedMs`
   timers. The connection MUST have announced `hotkey-target`; if it did
   not, → fallback.

Why a URL and not an Apple Event: every candidate app already handles URLs
(`onOpenURL` / `application(_:open:)`), the payload is one string, and
`activates = false` removes the only side effect that argued for an Apple
Event. A client receiving the wake URL MUST NOT open a window, change
document, or activate itself because of it; it connects (or reuses its
connection) and sends `hello{wakeRequestId}`. If it is not in a state to read
it SHOULD still connect and then `readDecline` so the fallback runs promptly
instead of after the wake budget.

### 16.6 Time budgets

All measured by the server. Values are minimums servers MUST allow; a server
MAY be more generous and MUST advertise the values it uses in `readRequest`.

| Phase | Budget | From | Until |
|---|---|---|---|
| Answer | `answerMs` ≥ 300 ms | `readRequest` sent | any of `read`, `readAccepted`, `readDecline` received |
| Accepted | `acceptedMs` ≥ 1500 ms | `readRequest` sent | `read` received, after a `readAccepted` |
| Wake | ≥ 1500 ms | wake URL opened | `hello{wakeRequestId}` received (consent time excluded, §16.5 step 5) |
| Cascade | `acceptedMs` total | hotkey | last `readRequest` sent to another connection after `notFocused` |

Clients SHOULD aim far below these: a pre-extracted or cached text answers in
single-digit milliseconds; a web-view extraction answers `readAccepted` at once
and `read` within ~100 ms.

### 16.7 Toggle on repeat

If the active session's owner resolves to the frontmost app (the user pressed
the key again in the app that is being read to), the hotkey is a
**pause/resume toggle** for that session, not a new request: `playing` or
`loading` → paused, `paused` → playing. The owner learns of it exactly as of
any server-side control: `state{paused}` / `state{playing}` (§6.4). A
finished or stopped session is not active; the next press starts a new
request. A press in a *different* app while a client session is active ends
that session (`ended{preempted, by:"Univocal"}`) and proceeds for the new app.

### 16.8 Fallback

The fallback is the server's existing behaviour: capture the frontmost app's
selection (or clipboard), read it in Univocal's panel, beep if empty. It runs
whenever routing cannot complete: the app is not a target (no connection and
no declaration, or connected without `hotkey-target`), the wake URL has no
handler or another app's (§16.5 step 2), wake or answer timed out, the client declined for any reason other than `notFocused` (or all
`notFocused` candidates are exhausted), the connection closed mid-request, or
the request's `read` was rejected (`invalidArgument`, `limitExceeded`…). The
server MUST NOT run the fallback after it accepted a client's `read` for the
same press, and MUST NOT run it twice for one press.

### 16.9 Connect at launch (quiet hello)

A client that announces `hotkey-target` SHOULD be connected whenever Univocal
is running, so the common case (the app has been granted before) needs no
wake. Rules:

* At its own launch, and whenever it notices the server start (watch
  `NSWorkspace.didLaunchApplicationNotification` for the server bundle id, or
  the appearance of `<ConnectDir>/connect.json`), the client connects **only
  if** a stored token exists **and** the discovery file shows a live server.
  It MUST NOT launch the server (§4.3) and MUST NOT cause a consent prompt at
  launch: it sends `hello{quiet:true}`. If the token is no longer valid the
  server answers `consentDenied{reason:"quiet"}` and closes; the client
  discards the token and relies on the wake path (§16.5) until the user acts.
* Without a token the client does nothing at launch; the first hotkey press
  wakes it (§16.5), the prompt appears once, and from then on it connects at
  launch.
* A quiet connection is otherwise ordinary: it may start reads, it receives
  `readRequest`s. Clients SHOULD keep it open for the life of the app and
  reconnect with the same rule after a disconnect (backoff ≥ 1 s, give up
  after a few tries until the next server launch is observed).

### 16.10 Browsers

Web pages cannot be targets directly (§9.4). The native-messaging host is a
child process of the browser, so its connection resolves to the browser by
ancestry (§16.3). The host announces `hotkey-target` only if the extension
told it to (a `{"type":"x-host-capabilities", "hotkeyTarget": true}` host-local
message, never forwarded). The host forwards `readRequest` to the extension
unchanged and forwards the extension's `readAccepted`/`readDecline`/`read`
unchanged (apart from the `hello` rewrite already required by §9.4). The
extension SHOULD answer `readAccepted` immediately, then pick the active tab of
the **last focused window** (`chrome.tabs.query({active:true,
lastFocusedWindow:true})`), ask its content script for the selection or
article text, and send `read{requestId}`. If the active tab has no content
script (browser-internal pages, the web store) it MUST `readDecline{reason:
"noContent"}`. Several browser windows are the browser's problem, not the
server's: one host connection per browser profile answers for all of them.

### 16.11 Edge cases

| Situation | Behaviour |
|---|---|
| Univocal's own panel or settings is frontmost | No routing; the server toggles its own reading as today. |
| Several windows of the target app | The client answers for its key window (or main window if none is key). A connection that owns no key/main window (per-window connections) declines `notFocused` so the server can ask the next one. |
| Target has a modal or sheet up | Client decides: read anyway, or `readDecline{busy}`. |
| Consent not yet granted | Only reachable via the wake path (a connection without a grant is not `ready`). The pending request survives the prompt (§16.5 step 5); after Allow the request is delivered right after `welcome`. |
| Univocal not running | The hotkey cannot fire. Clients never launch Univocal for hotkey purposes. |
| Frontmost app is connected but did not announce `hotkey-target` | Not a candidate → declaration check (it may still declare and be woken; a second connection with the capability may then appear) → else fallback. |
| Two hotkey presses in quick succession | Newest wins: the older request is dropped without fallback (§16.4). |
| Client's `read` answers in time but is invalid (`invalidArgument`, empty text) | `error` to the client as usual; the server runs the fallback. |
| Client answers with `preempt:false` | Ignored; a hotkey read always takes over (§5.4). |
| Client has nothing selected and `prefer:"selection"` | Read the document from the visible position (§16.12). Decline `noContent` only if there is no document at all. |
| Revoked while a request is pending | `unauthorized{revoked}` closes the connection → fallback. |

### 16.12 What a client should read (informative)

* `prefer:"selection"` and the key window has a non-empty selection → send
  the **whole visible document text** with `startOffset` at the selection's
  start, not just the selected substring: highlighting then continues past
  the selection the way Univocal's panel would, and the offsets stay
  meaningful for seek. A client that cannot map the selection into its
  document text MAY send only the selected text.
* No selection, or `prefer:"document"` → the document text with
  `startOffset` at the first fully visible block (the user hears what they
  are looking at). Clients SHOULD snap to a sentence or block start; the
  server snaps to the containing sentence anyway (§5.4).
* Editing surfaces where highlighting is impossible (a plain text editor
  view with no mapping back) → `readDecline{reason:"other", detail:"…"}`; the
  fallback reads the raw selection in the server's panel, which is the right
  answer there.
* The text is sent exactly as the client would for its own Read Aloud
  command; everything in §7 applies.

## Appendix A — JSON Schema sketch (informative)

```jsonc
// Common envelope
{ "type": string, "id"?: string|integer, "sessionId"?: string }

// C→S
hello      { protocol: "univocal-connect", versions: int[], client: {id,name,version,bundleId?}, capabilities?: string[], token?: string, quiet?: bool, wakeRequestId?: string }
read       { sessionId, text, lang?, voice?: string|null, rate?: number, startOffset?: int, preempt?: bool, ui?: "none"|"panel", more?: bool, meta?: {title?}, requestId?: string }
readAccepted { requestId }                                                     // hotkey-routing
readDecline  { requestId, reason: "noContent"|"busy"|"notFocused"|"userDisabled"|"other", detail?: string }
append     { sessionId, text, more: bool }
pause | resume | stop   { sessionId }
seek       { sessionId, offset: int }
setRate    { sessionId, rate: number }
listVoices { }
ping       { }

// S→C
welcome        { version: int, server: {name,version,bundleId}, capabilities: string[], limits: {maxFrameBytes, maxTextBytes, rate:{min,max}}, grant: {clientId, identity} }
consentPending { requestId, timeoutSeconds }
consentGranted { requestId, token }
consentDenied  { requestId, reason: "user"|"timeout"|"disabled"|"rateLimited"|"quiet" }
readRequest    { requestId, trigger: "hotkey", prefer: "selection"|"document", answerMs: int, acceptedMs: int }   // hotkey-routing
ok             { id, sessionId? }
state          { sessionId, state: "loading"|"playing"|"paused", detail?: string }
sentence       { sessionId, start, end }
word           { sessionId, start, end }
progress       { sessionId, offset }
rate           { sessionId, rate }
ended          { sessionId, reason: "finished"|"stopped"|"preempted"|"error"|"revoked", by?: string }
error          { id?, sessionId?, code, message, fatal: bool, reason?, field?, versions? }
voices         { id?, default: string, voices: [{id,name,lang}] }
pong           { id? }
```

## Appendix B — Info.plist declaration for hotkey routing (§16.5)

```xml
<key>UnivocalConnect</key>
<dict>
    <key>Versions</key>        <array><integer>1</integer></array>
    <key>HotkeyTarget</key>    <true/>
    <key>WakeURLScheme</key>   <string>previewmd</string>
</dict>
<!-- WakeURLScheme must be registered by the same bundle: -->
<key>CFBundleURLTypes</key>
<array><dict>
    <key>CFBundleURLName</key>    <string>com.narnarlabs.previewmd.url</string>
    <key>CFBundleURLSchemes</key> <array><string>previewmd</string></array>
    <key>LSHandlerRank</key>      <string>Owner</string>
</dict></array>
```

Wake URL the server opens: `previewmd://univocal-connect/read?requestId=h1&v=1`
(`NSWorkspace.shared.open(url, configuration:)` with `activates = false`).
Validation a client can run on itself at build or test time: the dict exists,
`Versions` is a non-empty array of integers containing 1, `HotkeyTarget` is a
boolean, `WakeURLScheme` is a lowercase scheme that appears in one of the
bundle's `CFBundleURLTypes.CFBundleURLSchemes`.
