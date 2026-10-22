# Univocal Connect — TypeScript client outline (Obsidian first, VS Code next)

Spec only; no package is published yet. This describes the shape of an
`@univocal/connect` style module and the plugin glue around it so that an
Obsidian plugin can be written against [SPEC.md](../SPEC.md) v1 in a weekend.

## 1. Environment facts that decide the design

* Obsidian and VS Code extension hosts run in **Node** (Electron main / extension
  host), so `net.connect({ path })` to the Unix socket works without any
  entitlement. Do **not** use the renderer's `WebSocket` — it sends an `Origin`
  header (`app://obsidian.md`) and the server refuses it (SPEC §3.2, §9.3).
* JavaScript string indices are UTF-16 code units — the spec's offset unit.
  Never convert through code points or `Array.from(str)`.
* Obsidian's `requestUrl`, `fetch`, and Capacitor APIs are irrelevant; plain
  Node `net`, `fs`, `os`, `child_process` are all that is needed. On mobile the
  plugin is simply unavailable (`Platform.isDesktopApp` gate).

## 2. Module layout

```
src/
  connect/
    paths.ts        connectDir(), discovery(), isServerAlive()
    ndjson.ts       NDJSON reader (Buffer → objects) and writer
    transport.ts    UdsTransport (net.Socket), reconnect/backoff, launch()
    client.ts       UnivocalClient: hello/consent/welcome, sessions, events
    types.ts        message types (mirrors SPEC Appendix A)
    tokenStore.ts   TokenStore interface + Obsidian impl (plugin data, see §6)
  obsidian/
    textMap.ts      editor text ↔ session text, reading-view DOM map
    highlighter.ts  CM6 decorations / CSS Custom Highlight in reading view
    main.ts         plugin: commands, status bar, settings tab
```

## 3. `paths.ts`

```ts
import os from "node:os"; import path from "node:path"; import fs from "node:fs";

export function connectDir(bundleId = "com.univocal.app"): string {
  if (process.env.UNIVOCAL_CONNECT_DIR) return process.env.UNIVOCAL_CONNECT_DIR;
  const app = bundleId.endsWith(".dev") ? "Univocal Dev" : "Univocal";
  return path.join(os.homedir(), "Library/Application Support", app, "Connect");
}

export interface Discovery { protocol: string; versions: number[]; socket: string;
  ws?: { url: string }; pid: number; server: { name: string; version: string; bundleId: string } }

export function readDiscovery(dir: string): Discovery | null {
  try { return JSON.parse(fs.readFileSync(path.join(dir, "connect.json"), "utf8")); }
  catch { return null; }
}

export function pidAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch (e: any) { return e.code === "EPERM"; }
}
```

Installed check: `execFile("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == 'com.univocal.app'"])`
(non-empty stdout) or `fs.existsSync("/Applications/Univocal.app")` as a fast path.
Launch: `execFile("/usr/bin/open", ["-g", "-b", bundleId, "--args", "--connect"])`.

## 4. `ndjson.ts`

* Reader: accumulate `Buffer` chunks; split on `0x0A`; strip a trailing `0x0D`;
  `JSON.parse` each line; enforce a 1 MiB line cap (close with a local error if
  exceeded — the server would have been at fault). Emit `object` events.
* Writer: `socket.write(JSON.stringify(msg) + "\n")`. Assert the serialised
  frame is ≤ `limits.maxFrameBytes` (default 1 MiB before `welcome`); the client
  layer splits text into `append` chunks well under that (e.g. 512 KiB).

## 5. `client.ts` — public surface

```ts
export type ConnectionState =
  | { kind: "disconnected"; error?: ConnectError }
  | { kind: "launching" } | { kind: "connecting" }
  | { kind: "awaitingConsent" }
  | { kind: "connected"; server: ServerInfo; capabilities: string[]; limits: Limits };

export type ReadingEvent =
  | { type: "state"; state: "loading" | "playing" | "paused"; detail?: string }
  | { type: "sentence"; start: number; end: number }
  | { type: "word"; start: number; end: number }
  | { type: "progress"; offset: number }
  | { type: "rate"; rate: number }
  | { type: "ended"; reason: "finished" | "stopped" | "preempted" | "error" | "revoked"; by?: string }
  | { type: "error"; code: string; message: string };

export class UnivocalClient extends EventEmitter /* 'state' */ {
  constructor(opts: { client: { id: string; name: string; version: string };
                      bundleId?: string; tokenStore: TokenStore; launchTimeoutMs?: number });
  availability(): Promise<"notInstalled" | "installed" | "running">;
  connect(opts?: { launch?: boolean }): Promise<ServerInfo>;   // resolves after welcome
  disconnect(): void;
  read(req: { text: string; sessionId?: string; lang?: string; voice?: string | null;
              rate?: number; startOffset?: number; preempt?: boolean; title?: string }): Promise<ReadingSession>;
}

export class ReadingSession extends EventEmitter /* 'event' (ReadingEvent) */ {
  readonly id: string;
  pause(): Promise<void>; resume(): Promise<void>; stop(): Promise<void>;
  seek(offset: number): Promise<void>; setRate(rate: number): Promise<void>;
}
```

Internals:

* `connect()`: read discovery → if stale/missing and `launch`, `open -g -b …
  --connect` then retry `net.connect` with 100 ms→1 s backoff up to 10 s → send
  `hello` with stored token → handle `consentPending` (emit `awaitingConsent`),
  `consentGranted` (store token; do **not** re-hello), `consentDenied` /
  `error{unauthorized}` (drop token if `revoked`; reject) → `welcome` resolves.
* Request/response: a `Map<id, {resolve, reject}>` keyed by a monotonically
  increasing integer `id`; `ok` resolves, `error` with matching `id` rejects.
* Events are routed by `sessionId` to the one live `ReadingSession`; `ended`
  marks it terminal and removes it.
* Unknown `type`s are ignored (SPEC §3.3). `ping` from the server → `pong`.

## 6. Token storage in Obsidian

Obsidian plugins have no Keychain. Options, in order of preference:

1. `safeStorage` from Electron is not reachable from plugins; **skip**.
2. `security add-generic-password` via `child_process` — works on macOS, no
   dependency, token never written to the vault. **Recommended.**
   `security find-generic-password -s com.univocal.connect -a <serverBundleId> -w`.
3. Plugin data (`this.saveData`) — lands inside the vault (syncable, plain
   text). Acceptable only with a settings warning; the server treats the
   identity as `unverified:<client.id>` anyway, so a leaked token is only as
   dangerous as the user's own machine, but a synced vault can leak it to other
   machines where it is useless (different uid, different socket) — low risk, but
   still prefer (2).

VS Code: use `context.secrets` (SecretStorage) — a proper Keychain-backed store.

## 7. Text ↔ document mapping

### 7.1 Editing view (CodeMirror 6)

* Session text = `view.state.doc.toString()` **exactly** (CM6 normalises to
  `\n`). Offsets then equal CM6 positions directly (`doc.toString()` indices are
  UTF-16 and CM6 positions are UTF-16 too).
* Optionally strip Markdown syntax for better speech? **No** — speaking the raw
  Markdown is wrong, but stripping breaks the identity mapping. Instead keep raw
  text and rely on Univocal's own cleaner being span-tracked *only if* the
  server advertises a future `markdown` capability. For v1, read in **reading
  view** (7.2) where the text is already rendered; the editing-view command
  reads the current selection or paragraph as plain text.
* Highlight: a `StateField<DecorationSet>` with two `Decoration.mark` classes
  (`uc-word`, `uc-sentence`); update on each `word`/`sentence` event via a
  `StateEffect`. If the document changes during a session (`tr.docChanged`),
  map the current sentence start through `tr.changes.mapPos`, stop the session
  and restart it from that offset with the new text (same rule as PreviewMD).

### 7.2 Reading view (rendered DOM)

Same algorithm as PreviewMD's `read-aloud.js`:

1. Walk `.markdown-reading-view .markdown-preview-sizer` text nodes with a
   `TreeWalker`; skip `pre`, `code` blocks' bodies, `.math`, `svg`, `img`,
   `.frontmatter`, `.internal-embed` (embeds have their own reading), and
   `[hidden]`.
2. Build `segments: { node: Text, start: number, length: number }[]` where
   `start` is the UTF-16 offset in the session text; append `"\n\n"` after each
   block element (`p, h1–h6, li, blockquote, td, th, dt, dd, figcaption`) and
   `"\n"` between inline-separated cells.
3. `rangeFor(start, end)`: binary-search segments → `document.createRange()`.
   Because wrapping does not reorder text nodes, store `{ block: Element,
   offsetInBlock }` instead of `Text` identities if a `<mark>` fallback is used
   (Obsidian ships a recent Electron, so `CSS.highlights` is available:
   `new Highlight(range)` → `CSS.highlights.set("univocal-word", h)` with
   `::highlight(univocal-word)` in `styles.css`).
4. Obsidian re-renders lazily on scroll (sections are virtualised): listen for
   `MutationObserver` on the sizer; when the current sentence's block is
   detached, re-extract and remap like PreviewMD (prefix/suffix diff → restart
   from the current sentence).

### 7.3 Click to seek

`document.caretRangeFromPoint(x, y)` → find the segment containing
`range.startContainer` → offset → `session.seek(offset)`.

## 8. Plugin glue (Obsidian)

* Commands: `univocal-read-aloud` (toggle play/pause; default hotkey left to
  the user), `univocal-stop`, `univocal-read-selection`.
* Status bar item shows connection/session state; click = pause/resume.
* Settings tab: Univocal status (not installed → link; installed → "Connected
  as …"), rate slider (sends `setRate`), "Forget authorisation" (deletes the
  token so the next read re-prompts in Univocal).
* `onunload`: `session?.stop()`, `client.disconnect()`, remove highlights.
* `client.id = "md.obsidian.plugin.univocal"`, `client.name = "Obsidian"`,
  `version = manifest.version`.

## 9. Conformance items a TS client must satisfy

From [CONFORMANCE.md](../CONFORMANCE.md) section B: C1–C12 and C14, plus
C15–C20, C22–C23 for hotkey routing (§10 below). The two that bite in
practice: C4 (chunk long notes with `append`; Obsidian notes can be multi-MB
when they embed base64 images — strip embeds first) and C9 (treat
`ended{preempted}` as a quiet stop, not an error toast).

## 10. Hotkey routing from an Obsidian plugin (SPEC §16)

The user presses Univocal's ⌥⇧R with Obsidian frontmost and expects the note
to be read **in Obsidian**. For a plugin this works only through the
**connected** path: the plugin cannot edit Obsidian's `Info.plist`, so there is
no `UnivocalConnect` declaration and no wake URL (SPEC §16.5 does not apply;
C21 is n/a). Everything therefore rests on §16.9 — being connected before the
key is pressed.

### 10.1 Why the plugin resolves to Obsidian

The plugin runs in Obsidian's **renderer** process (Electron's
`Obsidian Helper (Renderer)`), and Node's `net` is available there because
Obsidian enables Node integration. The socket's peer pid is the renderer, a
child of the Obsidian main process; its executable lives in
`Obsidian.app/Contents/Frameworks/Obsidian Helper (Renderer).app`. Both of the
server's tests in §16.3 pass (ancestry **and** bundle containment), so a
`readRequest` reaches the plugin whenever Obsidian is frontmost. No
`bundleId` claim is involved; nothing to configure.

### 10.2 Connect at launch, quietly

```ts
// main.ts
async onload() {
  this.client = new UnivocalClient({ client: { id: "md.obsidian.plugin.univocal", name: "Obsidian", version: manifest.version },
                                     tokenStore, capabilities: ["word-events", "sentence-events", "hotkey-target"] });
  this.client.on("readRequest", (req) => this.answer(req));
  await this.client.connectIfAuthorized();           // hello{quiet:true}; no launch, no prompt
  this.registerInterval(window.setInterval(() => this.reconnectIfServerAppeared(), 5_000));
}
```

`connectIfAuthorized()` = token present **and** `readDiscovery()` alive →
`hello{…, token, quiet: true}`; on `consentDenied{reason:"quiet"}` delete the
token and stay idle. Reconnect when `connect.json` reappears (poll every 5 s;
`fs.watch` on `<ConnectDir>` is fine on macOS too). Without a token the plugin
does nothing until the user runs a command once (`univocal-read-aloud`), which
connects normally and prompts in Univocal; from then on it connects at launch.

### 10.3 Answering `readRequest`

```ts
async answer(req: { requestId: string; prefer: "selection" | "document"; answerMs: number; acceptedMs: number }) {
  const leaf = this.app.workspace.getMostRecentLeaf();          // the active leaf of the focused window
  const view = leaf?.view instanceof MarkdownView ? leaf.view : null;
  if (!view) return this.client.decline(req.requestId, "noContent");
  if (!document.hasFocus() && this.app.workspace.getLeavesOfType("markdown").length > 1)
    return this.client.decline(req.requestId, "notFocused");     // a popout window owns the key window
  this.client.accept(req.requestId);                              // reading view extraction is async-ish; buy time

  if (view.getMode() === "source") {
    const editor = view.editor;
    const text = editor.getValue();                               // CM6 doc: offsets == positions
    const sel = editor.getSelection();
    const start = sel.length && req.prefer === "selection"
      ? editor.posToOffset(editor.getCursor("from"))
      : editor.posToOffset(editor.getCursor());                   // no selection: read from the caret
    return this.client.read({ text, startOffset: start, title: view.file?.basename }, { requestId: req.requestId });
  }
  // reading view: DOM text map (§7.2)
  const { text, offsetAtNode } = extractReadingView(view.containerEl);
  const domSel = window.getSelection();
  let start = 0;
  if (req.prefer === "selection" && domSel && !domSel.isCollapsed && view.containerEl.contains(domSel.anchorNode)) {
    start = offsetAtNode(domSel.getRangeAt(0).startContainer, domSel.getRangeAt(0).startOffset) ?? 0;
  } else {
    start = firstVisibleBlockOffset(view.containerEl, text);      // top of the viewport
  }
  return this.client.read({ text, startOffset: start, title: view.file?.basename }, { requestId: req.requestId });
}
```

Rules this encodes (SPEC §16.12, C16–C20):

* Exactly one answer per request; `accept` first because extraction may take
  more than a few ms on long notes (`acceptedMs` is ≥ 1.5 s; aim for < 100 ms).
* Whole document with `startOffset`, never just the selected substring, so
  reading continues past the selection and seek offsets stay valid.
* Source mode is readable in Obsidian (CM6 offsets are exact), unlike
  PreviewMD's plain `TextEditor`; so no `other` decline is needed here.
* `error{unknownRequest}` on the answering `read` (too late) → clear state, no
  toast.
* The toggle is server-side: a second ⌥⇧R arrives as `state{paused}` on the
  session; the plugin just reflects it in the status bar.

### 10.4 Client API additions for the TS module

```ts
interface UnivocalClientOptions { …; capabilities?: string[] }          // include "hotkey-target"
client.connectIfAuthorized(): Promise<ServerInfo | null>                 // quiet hello; null = no token / not running / quiet-denied
client.on("readRequest", (req: ReadRequestMessage) => void)
client.accept(requestId: string): void                                   // readAccepted
client.decline(requestId: string, reason: "noContent"|"busy"|"notFocused"|"userDisabled"|"other", detail?: string): void
client.read(req: ReadOptions, opts?: { requestId?: string }): Promise<ReadingSession>   // sets read.requestId
```

VS Code: identical, except the extension host is a child of the VS Code main
process (`Code Helper (Plugin)`), the active editor is
`vscode.window.activeTextEditor`, and `document.getText()` offsets equal
`document.offsetAt(position)` (UTF-16). VS Code's `Info.plist` is likewise not
editable by an extension, so the connected path is the only one.
