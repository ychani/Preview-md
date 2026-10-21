# Univocal Connect — Handoff to the Univocal software lead

Audience: the session that owns `~/workspace/univocal`. This document maps the
protocol in [SPEC.md](SPEC.md) onto Univocal's existing code and says in what
order to build it and how to validate it against the PreviewMD repo's mock and
conformance tooling. Nothing here has been changed in the Univocal repo; file
and function names below are from a read-only skim on 2026-10-21.

## 1. What already exists that Connect reuses

| Existing piece | Where | How Connect uses it |
|---|---|---|
| `Reader` — generates sentences ahead, plays in order, reports the current word via `onWord: (NSRange?)`, `onSentence`, `onState`, `onFinish` | `app/Univocal.swift` ~L1521–2040 | One `Reader` per Connect session. `NSRange` is already UTF-16, which is exactly the spec's offset unit (§7). |
| `Splitter.sentences(_:)` → `[Sentence]` with `offset` into the full text; `Splitter.locate(words:in:)` maps engine word tokens to `NSRange` with the 40-char window | `app/Univocal.swift` ~L1391–1520 | Produces `sentence` and `word` events directly. Needs `\n\n` (and preferably `\n`) treated as a sentence end (§7) — check `isSentenceEnd`. |
| `SpeechPlayer.currentTime` in file timeline, 1/32–32× | `app/SpeechPlayer.swift` | Playback clock for events; `rate` clamp reported via `limits.rate`. Advertise `{min: 0.25, max: 4}` to clients even though the player goes wider — keep the extreme range for the panel's own UI. |
| `Reader.seek(toChar:)`, `togglePause()`, `setSpeed`, `skip`, `stop()` | `app/Univocal.swift` ~L1891–2040 | `seek`, `pause`/`resume` (add explicit `pause()`/`resume()`; `togglePause` is ambiguous under a protocol), `setRate`, `stop`. |
| Engine normalisation with tracked spans: `normalize_other_tracked`, `restore_rewritten(words, text, spans)` | `engine/tts_server.py` ~L376–612 | Already maps rewritten words back to the original token. Verify the Connect path keeps `restore_rewritten` output (word `t` equal to the source token) so `Splitter.locate` finds `$5B`, not "five". |
| `Markdown.parse` → `CleanedText{spoken, display, map}` | `app/Markdown.swift` | **Not used for Connect.** Clients send plain text; Univocal must speak it as-is. Do not run `TextCleaner`/Markdown stripping on Connect text, or offsets break. If any cleaning is unavoidable, it must be span-tracked like the engine's. |
| `AppDelegate.read(_ raw:deferPanel:)` | `app/Univocal.swift` ~L5168 | Refactor into a `ReadingSource` enum (`.selection`, `.connect(ConnectSession)`); the panel-showing and HistoryStore calls become `.selection`-only. |
| `Supervisor.prepareReading()` | `app/Supervisor.swift` | Called on first `read`; its progress text becomes `state{loading, detail}`. |
| `Log.write` | `app/Log.swift` | Add `Log.connect(_:)` that is the only logger Connect code may call; it takes ids/lengths, never strings from clients. |
| `SettingsWindow` panes (sidebar `NSTableView` of `panes`) | `app/Settings.swift` ~L125–300 | New "Connected Apps" pane. |
| `build.sh` Info.plist heredoc | `app/build.sh` L79–114 | Add `CFBundleURLTypes` for `univocal`. |
| `main.swift` argument handling | `app/main.swift` | Add `--connect` (no-op flag: background launch). |
| `UnitTests.swift` + `tools/test.sh` tiers | `app/UnitTests.swift`, `tools/test.sh` | Protocol unit tests in `fast`; live probe in `models`. |

## 2. New code (suggested layout: `app/Connect/`)

1. **`ConnectPaths.swift`** — `connectDir` derived from the variant (`Univocal` / `Univocal Dev`) with `UNIVOCAL_CONNECT_DIR` override (and `kTestHome` like `Log.url` does); `socketURL`, `discoveryURL`; 0700/0600 creation; `sun_path` length fallback to `confstr(_CS_DARWIN_USER_TEMP_DIR)/univocal-connect/connect.sock`.
2. **`ConnectServer.swift`** — the listener. `NWListener` with `NWParameters(tls: nil, tcp: …)` and `requiredLocalEndpoint = .unix(path:)`; if that refuses to bind on the deployment target, fall back to POSIX `socket/bind/listen` + `DispatchSource.makeReadSource`. Accept loop → `ConnectConnection`. Writes/removes `connect.json` atomically. Starts in `applicationDidFinishLaunching` **before** engine or first-run work (§4.3).
3. **`ConnectConnection.swift`** — per-connection: NDJSON decoder with a 1 MiB cap, outbound queue with coalescing (§8), state `awaitingHello → consent → ready`, `getpeereid` uid check, identity resolution (`LOCAL_PEERTOKEN` → `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)` → `SecCodeCopySigningInformation` → `kSecCodeInfoTeamIdentifier` + `kSecCodeInfoIdentifier`; fallback `LOCAL_PEERPID` + `kSecGuestAttributePid`). Dispatches messages to `ConnectRouter`.
4. **`ConnectMessages.swift`** — `Codable` structs for every message in SPEC §5 / Appendix A, with a lenient decoder (unknown fields ignored, `id` as string-or-int).
5. **`ConnectGrants.swift`** — grant store at `<ConnectDir>/grants.json` (0600): `[ {clientId, identity, name, tokenSHA256, createdAt, lastUsedAt, revokedAt?} ]`. Token generation (`SecRandomCopyBytes`, 32 bytes, base64url, `uc1_`), lookup by hash, revocation with the 10-minute cool-down, per-identity consent rate limit, global enable switch stored in `Prefs`.
6. **`ConsentPrompt.swift`** — a small `NSPanel`/`NSAlert` queue: app name, bundle id or "Unverified build", icon (`NSWorkspace.shared.icon(forFile: peerBundlePath)` when the audit token yields a path, else a generic icon), Allow / Don't Allow, 120 s timeout. One at a time; others wait.
7. **`ConnectSessionController.swift`** — bridges one session to one `Reader`: translates `Reader.onSentence/onWord/onState/onFinish` into events; de-duplicates `word` (emit on range change only, but allow the identical-range repeat case the spec permits); implements `seek`, `setRate`, `pause`, `resume`, `stop`, `append` (concatenate; re-run `Splitter.sentences` on the new tail only, offsets continue). Enforces `maxTextBytes`.
8. **`ConnectRouter.swift`** — the single-active-session arbiter: owns `activeSession`, performs preemption in both directions (Connect→Connect, hotkey→Connect, Connect→hotkey), routes control messages with owner checks, emits `ended{preempted, by}`.
9. **`ConnectSettingsPane`** (in `Settings.swift`) — table of grants (app, identity badge, last used), Revoke button, "Allow other apps to use Univocal" checkbox, "Install browser bridge…" button (phase 3).
10. **`univocal-nm-host`** (phase 3) — tiny Swift executable in `Contents/Helpers/`, stdio native-messaging framing (4-byte LE length + JSON) ↔ Unix socket; manifest written to `~/Library/Application Support/{Google/Chrome,Vivaldi,Microsoft Edge,BraveSoftware/Brave-Browser}/NativeMessagingHosts/com.univocal.connect.json` by the settings button. Overrides `hello.client`.

## 3. Suggested order

| Phase | Deliverable | Validate with |
|---|---|---|
| 0 (½ day) | `ConnectPaths`, `ConnectMessages`, NDJSON codec, unit tests (framing, oversize, `\r\n`, id string/int, unknown fields). | `tools/test.sh` fast tier. |
| 1 (1–2 days) | `ConnectServer` + `ConnectConnection` with `hello`/`welcome`, `ping`, discovery file, uid check, **autogrant under `UNIVOCAL_CONNECT_AUTOGRANT=1` (dev only)**. | `univocal-mock check --dir "…/Univocal Dev/Connect"` from the PreviewMD repo: S1–S11, S19 should pass. |
| 2 (2 days) | `ConnectSessionController` + `ConnectRouter`: `read`, events from the playback clock, controls, preemption both ways, `--connect` flag, URL scheme. | Probe S19–S33; PreviewMD app end-to-end with `UNIVOCAL_BUNDLE_ID=com.univocal.app.dev`. |
| 3 (1–2 days) | Grants store, consent prompt, revocation, settings pane, logging audit. | Probe S12–S18 (+ manual S14/S17), log review for S34. |
| 4 (later) | WebSocket transport, native-messaging host. | S35–S36. |

## 4. Specific implementation notes

* **Offsets:** `Sentence.offset`, `Word.range` are `NSRange`s into the full
  text — exactly UTF-16. Guard against splitting a surrogate pair in
  `Splitter.locate` when the engine token begins or ends mid-pair (CJK with
  emoji; `NSString.rangeOfComposedCharacterSequence(at:)` widens correctly).
* **Expanded tokens:** today `locate` *skips* a token it cannot find. For
  Connect, a skipped token means a word with no highlight — acceptable, but the
  spec's preferred behaviour is to map each spoken word of an expansion to the
  source token's range (the "repeated identical range" case). If
  `restore_rewritten` already returns the source token text, nothing to do.
  Test fixture: `"Revenue reached $5B.\n\nNext year looks brighter."` must yield
  `word` ranges `[0,7) [8,15) [16,19)×n [22,26) [27,31) [32,37) [38,46)`.
* **`\n\n` boundary:** confirm `Splitter.isSentenceEnd` treats a blank line as
  terminal even without punctuation (headings, list items from clients have no
  trailing period).
* **Panel suppression:** for `ui:"none"` do not call `panel.showOnActiveSpace()`
  or `panel.setContent`; keep `setSpeaking` so the menu-bar icon reflects state.
  Space/Esc handling in the hidden panel must not fire.
* **Engine idle-out mid-session:** `Reader` already regenerates on failure; map
  that to `state{loading, detail}` then `playing`, or `error{engineError}` +
  `ended{error}` if it cannot recover.
* **Hotkey preemption:** in the refactored `read(source:)`, call
  `ConnectRouter.shared.preempt(by: "Univocal")` before `reader?.stop()`.
* **Audio cleanup:** sentence wavs for a Connect session are deleted at `ended`
  (§13). Check where `TTSClient` writes them and whether the panel path already
  cleans up.
* **Licensing gate:** `read` currently requires `licensed()`. Decide whether
  Connect sessions count toward trial limits; the spec has no opinion, but an
  unlicensed state should surface as `error{code:"internal", message:"Univocal
  licence required"}` + `ended{error}` rather than silence.
* **Logging:** audit every `Log.write` reachable from Connect code. Permitted:
  `connect: session S1 read len=61 lang=en client=com.narnarlabs.previewmd`.
  Forbidden: any substring of `text` or `meta.title`.
* **Discovery file:** write `connect.json` with `pid`, remove in
  `applicationWillTerminate`; on launch, if a stale file exists, overwrite it.

## 5. Open questions for the Univocal lead

1. `limits.rate`: advertise `0.25–4.0` (spec example) or the player's full
   `1/32–32`? Recommendation: 0.25–4.0; wider rates are a panel feature.
2. Should Connect reads appear in `HistoryStore.readings`? Recommendation: no
   (the client owns the document; privacy section §13 argues against).
3. Voice list for `listVoices`: expose Kokoro + Supertonic ids as-is, or a
   curated set? Recommendation: as-is, with `lang`.
4. Trial/licence behaviour for Connect sessions (see §4 above).
5. Does the dev build sign with a Team ID? If not, PreviewMD dev builds and
   Univocal Dev will both be "Unverified" — fine for development, but test at
   least once with a Developer ID-signed PreviewMD to see the verified path.
6. Native-messaging host: ship inside the app bundle (`Contents/Helpers`) and
   write manifests on demand, or install via the Settings pane only?

## 6. Validation against the PreviewMD repo

```sh
# 1. Build Univocal Dev with the listener, run it in the background
open -g -b com.univocal.app.dev --args --connect

# 2. From the PreviewMD repo, probe the live server
UNIVOCAL_CONNECT_AUTOGRANT=1   # set in Univocal Dev's environment for S12 without clicking
swift run univocal-mock check --dir "$HOME/Library/Application Support/Univocal Dev/Connect"

# 3. Drive it from the real client
UNIVOCAL_BUNDLE_ID=com.univocal.app.dev open -a PreviewMD   # Read Aloud ⇧⌘R

# 4. Compare behaviour with the reference mock whenever something is ambiguous
swift run univocal-mock --dir /tmp/uc-ref --consent auto --verbose
```

The probe's `S#` numbering matches [CONFORMANCE.md](CONFORMANCE.md). Wire the
probe into `tools/test.sh models` once phase 2 lands (it needs the engine for a
real `playing` state): clone or submodule the PreviewMD repo under `_workspace/`
or fetch the prebuilt `univocal-mock` binary from PreviewMD's release assets.
