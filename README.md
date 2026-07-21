# Preview-MD

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
- Full Xcode (not just Command Line Tools) — `make appex` / `make install-ql` require `xcode-select -p` to point at `/Applications/Xcode.app/Contents/Developer`
- Swift 5.9+

## Build & run

```bash
# Clone
git clone https://github.com/ychani/Preview-md.git
cd Preview-md

# Run in development
swift run Preview-MD

# Release build (executable binary)
swift build -c release

# Package as Preview-MD.app (contains the Quick Look .appex extension)
make app
open dist/Preview-MD.app

# Install to ~/Applications and register the Quick Look extension
make install-ql
```

## Quick Look extension

`make app` produces `dist/Preview-MD.app` with `Preview-MD-QL.appex` embedded in `Contents/PlugIns/`. The extension implements `QLPreviewingController` and renders Markdown with the same HTML shell as the main app.

To register it so Finder's Space-bar preview uses it:

```bash
make install-ql     # builds + copies to ~/Applications, then refreshes Quick Look
```

Notes:
- First launch the app once from `~/Applications/Preview-MD.app` so Launch Services records the bundle, then press Space on any `.md` file in Finder.
- The extension is registered per-user. On first use macOS may ask you to trust it in **System Settings → Privacy & Security → Extensions → Quick Look**.
- If previews don't show up, run `qlmanage -r && qlmanage -r cache` and retry.
- Since this is built with SPM (unsigned), macOS may block the extension under Gatekeeper. Right-click the app and choose Open the first time, or sign it with your own Developer ID for distribution.

## Project layout

```
preview-md/
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
│   ├── MdReader/                   # main app target (product: Preview-MD)
│   │   ├── MdReaderApp.swift       # @main, window + commands, onOpenURL
│   │   ├── ContentView.swift       # HSplitView + toolbar (view-mode picker)
│   │   ├── SidebarView.swift       # Folder header + file list
│   │   ├── EditorView.swift        # Monospaced TextEditor
│   │   ├── MarkdownPreviewView.swift  # WKWebView + safe render bridge
│   │   ├── AppState.swift          # state + open(url:) / openFile / openPanel
│   │   ├── MarkdownFile.swift      # Identifiable file model
│   │   └── ViewMode.swift          # .preview / .split / .edit
│   └── MdReaderQL/                 # Quick Look .appex (product: Preview-MD-QL)
│       ├── main.swift              # NSExtensionMain entry point
│       └── PreviewViewController.swift  # QLPreviewingController
├── packaging/
│   ├── Info.plist                  # app bundle plist (+ UTI export for markdown)
│   └── QLInfo.plist                # .appex plist (NSExtension + QL UTIs)
├── Makefile                        # `make app` / `make install-ql`
├── LICENSE
└── README.md
```

The internal Swift module names (`MdReader`, `MdReaderCore`, `MdReaderQL`) are kept identifier-safe for Swift imports. The user-facing product names are `Preview-MD` and `Preview-MD-QL`.

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

Preview-MD keeps no hidden state beyond standard preferences:

```bash
rm -rf ~/Applications/Preview-MD.app
defaults delete PreviewMD 2>/dev/null || true
qlmanage -r && qlmanage -r cache      # refresh Quick Look
```

## Contributing

PRs welcome. To get started:

1. Fork and clone
2. `swift build` to verify the build works
3. `swift run Preview-MD` to launch
4. Make your change, then `swift build && swift test`

CI runs `swift build -c release` and `swift test` on every push/PR. See [CHANGELOG.md](CHANGELOG.md) for release history.

Style: follow the surrounding code, no new dependencies without discussion, keep the app single-window and keyboard-friendly.

## License

MIT — see [LICENSE](LICENSE). Bundled JS: [marked](https://github.com/markedjs/marked) (MIT), [DOMPurify](https://github.com/cure53/DOMPurify) (Apache-2.0 OR MPL-2.0), [Mermaid](https://github.com/mermaid-js/mermaid) (MIT).
