# PreviewMD

A free, native macOS Markdown reader with a Quick Look extension — open a `.md` file and read it rendered, or press Space on one in Finder.

<!-- TODO: add docs/screenshot.png (main window, Split view) before launch -->
![PreviewMD showing a Markdown document in Split view](docs/screenshot.png)

## Features

- **Preview, Split, and Edit views** (⌘1 / ⌘2 / ⌘3) with GitHub-style rendering and automatic light/dark mode
- **Open files or folders** — double-click a `.md` / `.markdown` file, drop one on the Dock icon or window, or ⌘O; File → Open Recent
- **Folder sidebar** — a folder's Markdown files are one click away; the last folder is remembered
- **Auto-reload** — the preview follows changes made by another app (edit in your editor, read here)
- **Mermaid diagrams** — ```` ```mermaid ```` blocks render as diagrams in the app
- **Table of contents** panel and **Find** (⌘F, ⌘G / ⇧⌘G)
- **Safe rendering** — HTML is sanitized with DOMPurify and fails closed to plain text if the sanitizer is unavailable
- **Data-loss guards** — prompts before switching files or quitting with unsaved edits, and before overwriting a file that changed on disk
- **Encoding aware** — UTF-8, UTF-16, Latin-1/CP-1252, and Shift-JIS files open correctly and save back in their original encoding
- **Quick Look** — press Space on a Markdown file in Finder. Previews are rendered statically (marked via JavaScriptCore, no JavaScript in the preview, no Mermaid) and cannot load remote content
- Universal app (Apple silicon and Intel), macOS 13 Ventura or later

## Install

**Download:** grab the notarized `PreviewMD-<version>.dmg` from [GitHub Releases](https://github.com/ychani/Preview-md/releases), open it, and drag PreviewMD to Applications.

**Homebrew:**

```bash
brew install --cask ychani/tap/previewmd
```

### Enable Quick Look

1. Launch PreviewMD once from Applications so macOS registers its Quick Look extension.
2. Press Space on any `.md` file in Finder.
3. If the preview doesn't appear, make sure the extension is enabled — **System Settings → General → Login Items & Extensions → Quick Look** (macOS 15+) or **System Settings → Privacy & Security → Extensions → Quick Look** (macOS 13–14) — then run `qlmanage -r && qlmanage -r cache`.

### Uninstall

```bash
brew uninstall --cask previewmd          # Homebrew (add --zap to also remove preferences)
```

Or manually:

```bash
rm -rf /Applications/PreviewMD.app ~/Applications/PreviewMD.app
defaults delete com.narnarlabs.previewmd 2>/dev/null || true
qlmanage -r && qlmanage -r cache         # refresh Quick Look
```

**Upgrading from Preview-MD:** the app was renamed and its bundle ID changed (`com.preview-md.app` → `com.narnarlabs.previewmd`). Delete the old `Preview-MD.app` — otherwise Finder may keep using its Quick Look extension — and its preferences:

```bash
rm -rf ~/Applications/Preview-MD.app
defaults delete com.preview-md.app 2>/dev/null || true
```

`make install-ql` removes an old `~/Applications/Preview-MD.app` automatically (only if its bundle ID matches).

## Privacy

PreviewMD has no analytics, telemetry, accounts, or update checks, and makes no network requests of its own. All rendering libraries are bundled, and Quick Look previews never load remote content. Remote images in a document are blocked unless you choose to load them for that document. Links open in your browser only when you click them.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘O | Open file or folder… |
| ⌘S | Save |
| ⌘F | Find in preview |
| ⌘G / ⇧⌘G | Next / previous match |
| ⌘1 / ⌘2 / ⌘3 | Preview / Split / Edit |

## Build from source

Requirements:

- macOS 13 or later, Swift 5.9+
- **Full Xcode** for `swift test` (XCTest) and for the default universal (arm64 + x86_64) `make app`, which goes through Xcode's build system
- **Command Line Tools** are enough for `swift build`, `swift run PreviewMD`, and a single-architecture app: `make app ARCHS=arm64`

```bash
git clone https://github.com/ychani/Preview-md.git
cd Preview-md
swift run PreviewMD        # run in development (make run)
swift test                 # unit tests (make test)
make app                   # universal, ad-hoc-signed dist/PreviewMD.app with the Quick Look extension
make install-ql            # build, copy to ~/Applications, register Quick Look
```

Other targets: `make build` (release binaries only), `make clean`.

Builds from source are **ad-hoc signed** and not notarized. The first time macOS blocks one, open **System Settings → Privacy & Security**, find the message about PreviewMD, and click **Open Anyway** (on macOS 15+, right-click → Open no longer bypasses Gatekeeper).

### Releasing (maintainers)

`make release` builds, signs, notarizes, and staples the app, packages it into a DMG that is itself signed, notarized, and stapled, and creates a **draft** GitHub release (`v<version>`) whose notes are this version's section of [CHANGELOG.md](CHANGELOG.md). It needs:

- `SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"`
- a notarytool keychain profile named `previewmd` (`xcrun notarytool store-credentials previewmd …`; override with `NOTARY_PROFILE`)
- the `gh` CLI, authenticated

The version comes from `CFBundleShortVersionString` in `packaging/Info.plist`. Individual steps: `make notarize-app`, `make dmg`, `make notarize`, `make release-notes`. See the Distribution section of the [Makefile](Makefile). The Homebrew cask template lives in [packaging/homebrew/previewmd.rb](packaging/homebrew/previewmd.rb).

## Project layout

```
Package.swift                 SPM manifest: MdReaderCore, MdReader (PreviewMD), MdReaderQL (PreviewMD-QL)
Sources/
  MdReaderCore/               shared library
    MarkdownDocumentIO.swift      encoding-aware reading/writing
    MarkdownRenderBridge.swift    safe JS call builder for the WebView
    MarkdownHTMLRenderer.swift    static HTML rendering via JavaScriptCore (Quick Look)
    MdReaderCore.swift            resource-bundle lookup
    Resources/                    marked, DOMPurify, Mermaid, preview.html/.css, third-party notices
  MdReader/                   the app (SwiftUI + WKWebView): state, views, sidebar, TOC, find bar
  MdReaderQL/                 Quick Look extension (QLPreviewingController)
Tests/MdReaderCoreTests/      unit tests
packaging/                    Info.plists, Quick Look entitlements, app icon, Homebrew cask
Makefile                      app bundle, signing, notarization, DMG, release
```

Swift module names stay `MdReader*` for identifier-safe imports; the user-facing products are `PreviewMD` and `PreviewMD-QL`.

## Roadmap

Read-aloud with word highlighting via [Univocal](https://univocalapp.com) (coming).

## Contributing

Bug reports and small, focused PRs are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as described in [SECURITY.md](SECURITY.md). Release history: [CHANGELOG.md](CHANGELOG.md).

## License

MIT © NarNar Labs — see [LICENSE](LICENSE). Bundled third-party JavaScript ([marked](https://github.com/markedjs/marked), [DOMPurify](https://github.com/cure53/DOMPurify), [Mermaid](https://github.com/mermaid-js/mermaid)) is used under its own licenses — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
