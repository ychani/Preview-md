# Univocal Connect v1 — Conformance Checklist

Every item is a MUST from [SPEC.md](SPEC.md) phrased as a testable statement.
`§` points at the normative text. The last two columns say where the item is
exercised today:

* **Mock** — the `UnivocalMock` server in the PreviewMD repo (Swift package
  target; `swift run univocal-mock`) implements the server-side item, so client
  tests against the mock exercise the matching client item.
* **SDK tests** — `Tests/UnivocalClientTests` in the PreviewMD repo cover the
  client item (and, through the mock, the server item it depends on).
* **Probe** — `univocal-mock check --dir <ConnectDir>` runs the client-side
  probe against a *live* server (Univocal itself) and reports pass/fail per
  numbered item below. Items marked `manual` need a human (consent UI,
  revocation).

Legend: ✓ covered · ◐ partial · — not covered · manual.

## A. Server MUST items

| # | Requirement | § | Mock | SDK tests | Probe |
|---|---|---|---|---|---|
| S1 | Listens on `<ConnectDir>/connect.sock`; honours `UNIVOCAL_CONNECT_DIR`. | 3.1 | ✓ | ✓ | ✓ |
| S2 | `<ConnectDir>` is mode `0700`, socket `0600`; stale socket unlinked before bind. | 3.1 | ✓ | ✓ | ✓ |
| S3 | Closes connections whose peer uid ≠ own uid (`getpeereid`). | 3.1 | ◐ (uid check only) | — | manual (second account) |
| S4 | Accepts NDJSON frames up to ≥ 1 MiB; oversize frame → `protocolError` fatal. | 3.1 | ✓ | ✓ | ✓ |
| S5 | Tolerates `\r\n`; malformed JSON → `protocolError` fatal, no resync. | 3.1, 3.3 | ✓ | ✓ | ✓ |
| S6 | Unknown `type` with `id` → `error{unknownType}`; without `id` ignored; unknown fields ignored. | 3.3 | ✓ | ✓ | ✓ |
| S7 | Answers `ping` with `pong` echoing `id`. | 3.3 | ✓ | ✓ | ✓ |
| S8 | Maintains `connect.json` (`0600`, atomic) with `protocol`, `versions`, `socket`, `pid`, `server`; removes it on orderly shutdown. | 4.2 | ✓ | ✓ | ✓ |
| S9 | Starts the listener before engine/first-run work; `--connect` / `univocal://connect` keep the app in the background. | 4.3 | n/a | — | manual |
| S10 | First message must be `hello`; anything else → `protocolError` fatal. | 5.1 | ✓ | ✓ | ✓ |
| S11 | No common major version → `error{unsupportedVersion, versions}` fatal. | 5.1 | ✓ | ✓ | ✓ |
| S12 | Hello without/with unknown token → `consentPending`; grant → `consentGranted` **then** `welcome` on the same connection; denial → `consentDenied` then close. | 5.3 | ✓ (configurable) | ✓ | ✓ (autogrant env in dev) |
| S13 | Token revoked < 10 min ago → `error{unauthorized, reason:"revoked"}` fatal, no re-prompt. | 5.3 | ✓ | ✓ | manual |
| S14 | Shows a consent prompt naming app and identity; never auto-grants in release. | 6.1 | n/a | — | manual |
| S15 | ≤ 1 visible prompt; ≤ 1 pending per connection; > 3/min per identity → `consentDenied{rateLimited}`. | 6.1 | ✓ | ✓ | — |
| S16 | Tokens: 32 random bytes base64url `uc1_`; only SHA-256 stored with the grant record. | 6.1 | ✓ | ✓ (format) | ✓ (format) |
| S17 | Revocation ends the identity's session (`ended{revoked}`) and closes its connections (`unauthorized` fatal). | 6.1 | ✓ | ✓ | manual |
| S18 | Identity string per §6.2; token bound to `(clientId, identity)`; mismatch → treated as no token. | 6.2 | ◐ (unverified only) | ✓ | ✓ (reports identity) |
| S19 | `read` accepted → `ok{id}` then `state{loading}`; `sessionId` reuse on same connection → `sessionExists`. | 5.4, 5.6 | ✓ | ✓ | ✓ |
| S20 | `read{preempt:true}` ends any active session anywhere with `ended{preempted}` to its owner; `preempt:false` while busy → `busy`. | 5.4, 6.4 | ✓ | ✓ | ✓ (two connections) |
| S21 | Univocal's own reading preempts a Connect session (`by:"Univocal"`). | 6.4 | n/a | — | manual |
| S22 | Control from non-owner → `notOwner`; unknown/ended session → `noSession`. | 5.5 | ✓ | ✓ | ✓ |
| S23 | `seek.offset` out of `[0,len]` → `invalidOffset`; in range moves to containing/next word and keeps play state. | 5.5 | ✓ | ✓ | ✓ |
| S24 | `setRate` clamped to `limits.rate`; effective value announced by `rate` event. | 5.5, 5.7 | ✓ | ✓ | ✓ |
| S25 | `stop` → `ended{stopped}`; `ended` is the last message for the session. | 5.5, 5.7 | ✓ | ✓ | ✓ |
| S26 | `sentence` precedes the first `word` of that sentence; all ranges half-open, `start < end`, within text length. | 5.7 | ✓ | ✓ | ✓ |
| S27 | Events only to the owner; nothing about a session to other connections. | 5.7, 6.4 | ✓ | ✓ | ✓ |
| S28 | Offsets are UTF-16 code units into the unmodified text; expanded tokens map to the source range; ranges never split a surrogate pair. | 7 | ✓ | ✓ (emoji/CRLF fixtures) | ✓ (fixture text) |
| S29 | `\n\n` is a sentence boundary. | 7 | ✓ | ✓ | ✓ |
| S30 | Chunking: `more:true` + `append`; global offsets; trailing partial sentence not synthesised early; `> maxTextBytes` → `limitExceeded` + `ended{error}`. | 8 | ✓ | ✓ | ◐ (sizes) |
| S31 | Outbound coalescing drops superseded `word/sentence/progress` only; never state/ended/error/ok/welcome/consent; > 4 MiB → `slowConsumer` fatal. | 8 | ✓ | ✓ (slow reader) | — |
| S32 | `error` carries `code`, `message`, `fatal`; fatal errors are followed by close. | 5.8, 10 | ✓ | ✓ | ✓ |
| S33 | `welcome.limits.maxFrameBytes ≥ 1048576`; `limits.rate.min ≤ 1 ≤ max`. | 5.2 | ✓ | ✓ | ✓ |
| S34 | Never logs text, titles, or offsets with text; stores only token hashes; deletes session audio at end. | 13 | ✓ (mock logs lengths) | — | manual (log review) |
| S35 | WebSocket (if offered): loopback only, text frames only, `Origin` present → 403, token required. | 3.2 | — (not in mock v1) | — | ◐ (Origin probe if `ws` advertised) |
| S36 | Native-messaging host (if shipped) overrides `hello.client` with the extension identity and forwards everything else unchanged. | 9.4 | — | — | manual |

## B. Client MUST items

| # | Requirement | § | Mock | SDK tests | Probe |
|---|---|---|---|---|---|
| C1 | Prefers `connect.json`'s `socket` path over the well-known path; treats dead `pid` as not running. | 3.1, 4.2 | ✓ | ✓ | n/a |
| C2 | Sends `hello` first with `protocol`, `versions`, `client.{id,name,version}`; `client.id` matches `[A-Za-z0-9._-]{1,128}`. | 5.1 | ✓ (validates) | ✓ | n/a |
| C3 | Ignores unknown message types and fields. | 3.3 | ✓ (mock injects) | ✓ | n/a |
| C4 | Never splits a JSON message across frames; frames ≤ `maxFrameBytes`; uses `append` beyond that. | 3.1, 8 | ✓ | ✓ | n/a |
| C5 | On `consentPending` shows a waiting state; on `consentGranted` stores the token securely (Keychain) keyed by server `bundleId` and does **not** re-send `hello`. | 5.3 | ✓ | ✓ (InMemory + Keychain) | n/a |
| C6 | Presents the stored token on later `hello`s; on `unauthorized{revoked}` discards it and surfaces "not authorised" without auto-retrying for 10 min. | 5.3 | ✓ | ✓ | n/a |
| C7 | Offsets it sends (`startOffset`, `seek.offset`) are UTF-16 indices into exactly the text it sent; `\n` line endings. | 7 | ✓ | ✓ | n/a |
| C8 | Applies `word`/`sentence` ranges as UTF-16 half-open ranges; tolerates repeated identical ranges without re-animating. | 5.7, 7 | ✓ | ✓ | n/a |
| C9 | Treats `ended` as terminal and clears highlights; handles `preempted` without error UI. | 5.7 | ✓ | ✓ | n/a |
| C10 | Sends control messages only for sessions it owns; one live `sessionId` per read. | 5.5 | ✓ | ✓ | n/a |
| C11 | Only sends `listVoices`/`progress`-gated/`panel` requests when the server announced the capability. | 11 | ✓ | ✓ | n/a |
| C12 | Launch-on-demand with `--connect`, retries with backoff ≤ 10 s, reports failure. | 4.3 | ◐ (mock launched by tests) | ✓ (timeout path) | n/a |
| C13 | Does not log received offsets with document text at shipping log levels. | 13 | — | — | manual |
| C14 | Node/Electron clients connect from the Node context over the Unix socket, not the renderer WebSocket. | 9.3 | — | — | manual (code review) |

## C. How to run

```sh
# PreviewMD repo
swift test --filter UnivocalClientTests          # client items + mock server items
swift run univocal-mock --dir /tmp/uc-qa --consent ask --verbose   # manual QA server
UNIVOCAL_CONNECT_DIR=/tmp/uc-qa open -a PreviewMD                  # app against the mock

# Against a live Univocal (dev build), from the PreviewMD repo
swift run univocal-mock check --dir "$HOME/Library/Application Support/Univocal Dev/Connect"
```

The probe prints one line per `S#` item it can evaluate (`PASS`, `FAIL <why>`,
`SKIP manual`). Univocal's own test tier (`tools/test.sh models`) is expected to
invoke the probe once the Connect listener lands; see UNIVOCAL_HANDOFF.md §6.
