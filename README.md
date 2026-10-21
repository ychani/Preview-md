# PreviewMD

A free, native macOS Markdown reader with a Quick Look extension — open a `.md` file and read it rendered, or press Space on one in Finder.

<!-- TODO: add docs/screenshot.png (main window, Split view) before launch -->
![PreviewMD showing a Markdown document in Split view](docs/screenshot.png)

## Features

**Reading & editing**

- **Preview, Split, and Edit views** (⌘1 / ⌘2 / ⌘3) with GitHub-style rendering and automatic light/dark mode
- **Open files or folders** — double-click a `.md` / `.markdown` file, drop files on the Dock icon or window, or ⌘O (select several at once); File → Open Recent
- **Auto-reload** — the preview follows changes made by another app; if you have unsaved edits, PreviewMD asks before reloading
- **Mermaid diagrams**, **table of contents** panel, and **Find** (⌘F, ⌘G / ⇧⌘G)
- **Links and images** — `#heading` links scroll in place, links to other `.md` files open them, and relative images (`./img/pic.png`) load from disk
- **Zoom** the preview and editor (⌘+ / ⌘− / ⌘0)
- **Window title** shows the file name with a proxy icon (⌘-click for the path menu); the subtitle shows its folder. File → Reveal in Finder, Copy Path, Copy Relative Path
- **Data-loss guards** — prompts before switching files, opening another file or folder, or quitting with unsaved edits, and before overwriting a file that changed on disk
- **Encoding aware** — UTF-8, UTF-16, Latin-1/CP-1252, and Shift-JIS files open correctly and save back with their original encoding, byte-order mark, and line endings
- **Large files** — files over 5 MB open read-only
- VoiceOver labels for toolbar, sidebar, Find bar, and table-of-contents controls

**Explorer & workspace**

- **Folder tree** — open a folder to browse every Markdown file in its subfolders, VS Code style: folders first, Finder order; hidden folders and `node_modules` are skipped; up to 20,000 files (a notice says when the list is capped)
- **Live updates** — new, deleted, and renamed files appear within about a second; expanded folders and the selection are kept, and the selected file is revealed in the tree
- **Context menu** — Reveal in Finder, Copy Path, Copy Relative Path; every row shows its full path as a tooltip
- **Multi-root workspace** — File → Add Folder to Workspace… (⌥⌘O) or the sidebar's ＋ menu adds a folder as another top-level root; remove one with Remove Folder from Workspace (nothing is deleted on disk). Nested or duplicate folders are refused with a notice. Opening a folder replaces the workspace; the workspace is restored on the next launch
- **Opened-files list** — individually opened files show their parent folder, so two `README.md` files can be told apart

**Obsidian-friendly**

- **Front matter** — a leading YAML block renders as a compact properties table (a leading `---` horizontal rule still works)
- **Wikilinks** — `[[note]]`, `[[note|alias]]`, `[[note#heading]]`, `[[folder/note]]` resolve across the open workspace like Obsidian (case-insensitive; an exact path wins, then the note's own folder, then the shortest path). Links to missing notes are dimmed; clicking a link opens the note and scrolls to the heading
- **Image embeds** — `![[image.png]]`, with optional `|300` or `|300x200` size, load from anywhere inside the same workspace folder (including image-only folders such as `attachments/`); note embeds `![[note]]` show as links

**Quick Look**

- Press Space on a Markdown file in Finder. Previews are rendered statically (marked via JavaScriptCore, no JavaScript in the preview, no Mermaid), include front-matter tables, and show wikilinks as styled text without navigation. Files over 2 MB are truncated with a notice

**Privacy**

- **Remote images are blocked** — a document that references them shows a "Load remote images" banner; the choice applies to that document only and is not saved
- **Safe rendering** — HTML is sanitized with DOMPurify under a strict Content-Security-Policy, and fails closed to plain text if the sanitizer is unavailable
- Local images load only from inside the document's workspace folder (or its own folder when opened on its own), and only image files

Universal app (Apple silicon and Intel), macOS 13 Ventura or later.

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
| ⌥⌘O | Add Folder to Workspace… |
| ⌘S | Save |
| ⌘1 / ⌘2 / ⌘3 | Preview / Split / Edit |
| ⌘F | Find in preview |
| ⌘G / ⇧⌘G | Next / previous match |
| ⌘+ / ⌘− / ⌘0 | Zoom in / zoom out / actual size |
| ⌥⌘R | Reveal in Finder |
| ⌥⌘C | Copy Path |
| ⇧⌥⌘C | Copy Relative Path (file inside the workspace) |

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
    MarkdownDocumentIO.swift      encoding-, BOM- and line-ending-aware reading/writing
    MarkdownRenderBridge.swift    safe JS call builder for the WebView, CSP, local image/link resolution
    MarkdownHTMLRenderer.swift    static HTML rendering via JavaScriptCore (Quick Look)
    FileWatcher.swift             watches the open file (survives atomic saves)
    FileNode.swift                explorer tree node, Finder-style sort
    FilePathDisplay.swift         relative paths, tooltips, duplicate-name labels
    FolderScanner.swift           metadata-only recursive folder scan (Markdown + images)
    FolderTree.swift              explorer model with in-place subtree refresh
    FolderWatcher.swift           FSEvents watcher for live folder updates
    Workspace.swift               multi-root workspace roots and their bookmarks
    WikiLink.swift                wikilink parsing and workspace-wide resolution
    MdReaderCore.swift            resource-bundle lookup
    Resources/                    marked, DOMPurify, Mermaid, markdown-extensions.js (front matter,
                                  wikilinks), preview.html/.js/.css, third-party notices
  MdReader/                   the app (SwiftUI + WKWebView)
    AppState.swift                documents, workspace, watchers, wikilink index
    SidebarView.swift             folder tree and opened-files list
    MarkdownPreviewView.swift     preview WebView
    LocalImageSchemeHandler.swift serves local images to the preview (previewmd-local: scheme)
    FileLocationActions.swift     Reveal in Finder / Copy Path / Copy Relative Path
    PreviewSettings.swift         preview and editor zoom
    …                             editor, find bar, TOC, menus
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
