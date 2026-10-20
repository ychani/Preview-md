# PreviewMD

A lightweight, native macOS Markdown reader and editor. Double-click a `.md` file, drag one onto the Dock icon, or open a folder from the sidebar — then switch between Preview, Split, and Edit views.

Built with SwiftUI + WKWebView. Zero Swift dependencies. Markdown rendered with a vendored copy of [marked](https://github.com/markedjs/marked) and sanitized with [DOMPurify](https://github.com/cure53/DOMPurify).

## Features

- **Open files or folders** — double-click a `.md` in Finder, drop one on the Dock icon or window, or pick a file/folder from the open panel (⌘O); recent files in File → Open Recent
- **Sidebar folder browser** — when you open a folder, its Markdown files populate the sidebar so siblings are one click away
- **Three view modes** — Preview, Split, Edit (⌘1 / ⌘2 / ⌘3)
- **Live preview** — WKWebView-rendered, GitHub-style CSS, light/dark mode
- **Auto-reload** — the preview refreshes when the open file is changed by another app (edit in your editor, read here)
- **Mermaid diagrams** — fenced ```` ```mermaid ```` blocks render as diagrams (loaded on demand)
- **Table of contents** — toggleable ToC panel built from the document's headings
- **Find in preview** — ⌘F with match count and next/previous
- **Safe rendering** — DOMPurify sanitizes HTML (fails closed to plain text if unavailable); external links open in the default browser
- **Data-loss guards** — warns before switching files or quitting with unsaved edits, and before overwriting a file that changed on disk
- **Encoding aware** — UTF-8, UTF-16, Latin-1/CP-1252, and Shift-JIS files open correctly and save back in their original encoding
- **Persistent folder** — remembers your last folder via security-scoped bookmark
- **Finder Quick Look** — press Space on any `.md` / `.markdown` file for a rendered preview

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9+
- **Command Line Tools** are enough for `swift build`, `swift run PreviewMD`, and a single-architecture app: `make app ARCHS=arm64`
- **Full Xcode** (`xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`) is needed for `swift test` (XCTest) and for the default universal (arm64 + x86_64) `make app`, which uses Xcode's build system

## Build & run

```bash
# Clone
git clone https://github.com/ychani/Preview-md.git
cd Preview-md

# Run in development
swift run PreviewMD

# Release build (executable binary)
swift build -c release

# Package as a universal, ad-hoc-signed PreviewMD.app (contains the Quick Look .appex)
make app                 # or: make app ARCHS=arm64  (Command Line Tools only)
open dist/PreviewMD.app

# Install to ~/Applications and register the Quick Look extension
make install-ql
```

## Quick Look extension

`make app` produces `dist/PreviewMD.app` with `PreviewMD-QL.appex` embedded in `Contents/PlugIns/`. The extension implements `QLPreviewingController` and renders Markdown with the same HTML shell as the main app.

To register it so Finder's Space-bar preview uses it:

```bash
make install-ql     # builds + copies to ~/Applications, then refreshes Quick Look
```

Notes:
- First launch the app once from `~/Applications/PreviewMD.app` so Launch Services records the bundle, then press Space on any `.md` file in Finder.
- The extension is registered per-user. On first use macOS may ask you to trust it in **System Settings → Privacy & Security → Extensions → Quick Look**.
- If previews don't show up, run `qlmanage -r && qlmanage -r cache` and retry.
- **Upgrading from Preview-MD:** the app was renamed and its bundle ID changed (`com.preview-md.app` → `com.narnarlabs.previewmd`). `make install-ql` removes an old `~/Applications/Preview-MD.app` automatically (only if its bundle ID matches); if you installed it elsewhere, delete it yourself — otherwise Finder may keep using its Quick Look extension. Old preferences: `defaults delete com.preview-md.app 2>/dev/null || true`.

## Gatekeeper

Release DMGs are signed with a Developer ID and notarized by Apple, so they open normally.

Builds from source (`make app`) are **ad-hoc signed** and not notarized. The first time macOS blocks one, open **System Settings → Privacy & Security**, scroll to the message about PreviewMD, and click **Open Anyway**. (On macOS 15 Sequoia and later, right-click → Open no longer bypasses Gatekeeper.)

Maintainers: `make release` with `SIGN_IDENTITY="Developer ID Application: …"` and a `previewmd` notarytool keychain profile signs, notarizes, and staples both the app and the DMG — see the Distribution section of the `Makefile`.

## Project layout

```
PreviewMD/
├── Package.swift                   # SPM manifest (3 targets)
├── Sources/
│   ├── MdReaderCore/               # shared library: resources + render bridge
│   │   ├── MdReaderCore.swift      # public resource accessor (Bundle.module)
│   │   ├── MarkdownRenderBridge.swift  # safe JS call builder
│   │   ├── MarkdownDocumentIO.swift    # encoding-aware file reading
│   │   └── Resources/
│   │       ├── marked.min.js       # vendored markdown parser (MIT)
│   │       ├── purify.min.js       # vendored HTML sanitizer (Apache-2.0 / MPL-2.0)
│   │       ├── preview.html        # WebView shell + render bridge
│   │       └── preview.css         # GitHub-style CSS, auto dark mode
│   ├── MdReader/                   # main app target (product: PreviewMD)
│   │   ├── MdReaderApp.swift       # @main, window + commands, onOpenURL
│   │   ├── ContentView.swift       # HSplitView + toolbar (view-mode picker)
│   │   ├── SidebarView.swift       # Folder header + file list
│   │   ├── EditorView.swift        # Monospaced TextEditor
│   │   ├── MarkdownPreviewView.swift  # WKWebView + safe render bridge
│   │   ├── AppState.swift          # state + open(url:) / openFile / openPanel
│   │   ├── MarkdownFile.swift      # Identifiable file model
│   │   └── ViewMode.swift          # .preview / .split / .edit
│   └── MdReaderQL/                 # Quick Look .appex (product: PreviewMD-QL)
│       ├── main.swift              # NSExtensionMain entry point
│       └── PreviewViewController.swift  # QLPreviewingController
├── packaging/
│   ├── Info.plist                  # app bundle plist (+ markdown UTI import)
│   └── QLInfo.plist                # .appex plist (NSExtension + QL UTIs)
├── Makefile                        # `make app` / `make install-ql`
├── LICENSE
└── README.md
```

The internal Swift module names (`MdReader`, `MdReaderCore`, `MdReaderQL`) are kept identifier-safe for Swift imports. The user-facing product names are `PreviewMD` and `PreviewMD-QL`.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘O       | Open file or folder… |
| ⌘S       | Save current file |
| ⌘F       | Find in preview |
| ⌘1       | Preview mode |
| ⌘2       | Split mode |
| ⌘3       | Edit mode |

## Uninstall

PreviewMD keeps no hidden state beyond standard preferences:

```bash
rm -rf ~/Applications/PreviewMD.app
defaults delete com.narnarlabs.previewmd 2>/dev/null || true
qlmanage -r && qlmanage -r cache      # refresh Quick Look
```

If you also have the pre-rename build, remove it too:

```bash
rm -rf ~/Applications/Preview-MD.app
defaults delete com.preview-md.app 2>/dev/null || true
```

## Contributing

PRs welcome. To get started:

1. Fork and clone
2. `swift build` to verify the build works
3. `swift run PreviewMD` to launch
4. Make your change, then `swift build && swift test`

CI runs `swift build -c release` and `swift test` on every push/PR. See [CHANGELOG.md](CHANGELOG.md) for release history.

Style: follow the surrounding code, no new dependencies without discussion, keep the app single-window and keyboard-friendly.

## License

MIT — see [LICENSE](LICENSE). Bundled third-party JavaScript ([marked](https://github.com/markedjs/marked), [DOMPurify](https://github.com/cure53/DOMPurify), [Mermaid](https://github.com/mermaid-js/mermaid)) is used under its own licenses — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
