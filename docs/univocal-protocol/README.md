# Univocal Connect

A versioned local protocol through which any Mac app asks
[Univocal](https://univocalapp.com) to read text aloud and receives word- and
sentence-level progress so the app can highlight its own UI. Univocal speaks and
owns playback; clients highlight. Text never leaves the Mac.

PreviewMD is the first reference client; Obsidian and VS Code plugins, CLIs and
browsers (through a native-messaging host) are the intended next ones.

| File | What it is |
|---|---|
| [SPEC.md](SPEC.md) | The normative specification, v1: transports (Unix socket + optional loopback WebSocket), discovery, handshake, consent, sessions, events, offsets, chunking, security, versioning, transcript. |
| [CONFORMANCE.md](CONFORMANCE.md) | Numbered, testable MUST items for servers (S#) and clients (C#), with coverage by the mock server, the Swift SDK tests and the live-server probe. |
| [UNIVOCAL_HANDOFF.md](UNIVOCAL_HANDOFF.md) | For the Univocal team: what changes on the server side, mapped to Univocal's files, in what order, and how to validate against this repo's tooling. |
| [clients/typescript-outline.md](clients/typescript-outline.md) | Outline of a TypeScript client for Obsidian/VS Code/Node: UDS via `net`, NDJSON, CodeMirror/DOM range mapping. |
| [LICENSE](LICENSE) | MIT, © 2026 NarNar Labs — the protocol documents and the reference client code are free for anyone to implement. |

Reference client code in this repository (when landed): `Sources/UnivocalClient`
(Swift SDK), `Sources/UnivocalMock` + `univocal-mock` (conformant mock server and
live-server probe), `Tests/UnivocalClientTests`.

Quick taste, from a shell:

```sh
printf '%s\n' '{"type":"hello","protocol":"univocal-connect","versions":[1],"client":{"id":"sh.example.cli","name":"cli","version":"0"}}' \
  '{"type":"read","id":1,"sessionId":"s1","text":"Hello from the shell."}' \
  | nc -U "$HOME/Library/Application Support/Univocal/Connect/connect.sock"
```
