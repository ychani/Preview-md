# md-reader

A lightweight, native macOS markdown reader and editor. Open a folder, browse its Markdown files in the sidebar, and switch between Preview, Split, and Edit views.

Built with SwiftUI + WKWebView. Zero Swift dependencies. Markdown rendered with a vendored copy of [marked](https://github.com/markedjs/marked) and sanitized with [DOMPurify](https://github.com/cure53/DOMPurify).

## Features

- **Sidebar folder browser** — pick a folder, see all `.md` / `.markdown` files
- **Three view modes** — Preview, Split, Edit (⌘1 / ⌘2 / ⌘3)
- **Live preview** — WKWebView-rendered, GitHub-style CSS, light/dark mode
- **Safe rendering** — DOMPurify sanitizes HTML; external links open in the default browser
- **Unsaved-changes guard** — warns before switching files with unsaved edits
- **Persistent folder** — remembers your last folder via security-scoped bookmark
- **Finder Quick Look** — press Space on any `.md` / `.markdown` file for a rendered preview

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`) or full Xcode
- Swift 5.9+

## Build & run

```bash
# Clone
git clone https://github.com/<your-org>/md-reader.git
cd md-reader

# Run in development
swift run

# Release build (executable binary)
swift build -c release

# Package as MdReader.app (contains the Quick Look .appex extension)
make app
open dist/MdReader.app

# Install to ~/Applications and register the Quick Look extension
make install-ql
```

## Quick Look extension

`make app` produces `dist/MdReader.app` with `MdReaderQL.appex` embedded in `Contents/PlugIns/`. The extension implements `QLPreviewingController` and renders Markdown with the same HTML shell as the main app.

To register it so Finder's Space-bar preview uses it:

```bash
make install-ql     # builds + copies to ~/Applications, then refreshes Quick Look
```

Notes:
- First launch the app once from `~/Applications/MdReader.app` so Launch Services records the bundle, then press Space on any `.md` file in Finder.
- The extension is registered per-user. On first use macOS may ask you to trust the extension in **System Settings → Privacy & Security → Extensions → Quick Look**.
- If previews don't show up, run `qlmanage -r && qlmanage -r cache` and retry.
- Since this is built with SPM (unsigned), macOS may block the extension under Gatekeeper. Right-click the app and choose Open the first time, or sign it with your own Developer ID for distribution.

## Project layout

```
md-reader/
├── Package.swift                   # SPM manifest (3 targets)
├── Sources/
│   ├── MdReaderCore/               # shared library: resources + render bridge
│   │   ├── MdReaderCore.swift      # public resource accessor (Bundle.module)
│   │   ├── MarkdownRenderBridge.swift  # safe JS call builder
│   │   └── Resources/
│   │       ├── marked.min.js       # vendored markdown parser (MIT)
│   │       ├── purify.min.js       # vendored HTML sanitizer (Apache-2.0 / MPL-2.0)
│   │       ├── preview.html        # WebView shell + render bridge
│   │       └── preview.css         # GitHub-style CSS, auto dark mode
│   ├── MdReader/                   # the main app (depends on MdReaderCore)
│   │   ├── MdReaderApp.swift       # @main, window + commands
│   │   ├── ContentView.swift       # HSplitView + toolbar (view-mode picker)
│   │   ├── SidebarView.swift       # Folder header + file list
│   │   ├── EditorView.swift        # Monospaced TextEditor
│   │   ├── MarkdownPreviewView.swift  # WKWebView + safe render bridge
│   │   ├── AppState.swift          # Observable state + folder/file I/O
│   │   ├── MarkdownFile.swift      # Identifiable file model
│   │   └── ViewMode.swift          # .preview / .split / .edit
│   └── MdReaderQL/                 # Quick Look .appex extension
│       ├── main.swift              # NSExtensionMain entry point
│       └── PreviewViewController.swift  # QLPreviewingController
├── packaging/
│   ├── Info.plist                  # app bundle plist (+ UTI export for markdown)
│   └── QLInfo.plist                # .appex plist (NSExtension + QL UTIs)
├── Makefile                        # `make app` / `make install-ql`
├── LICENSE
└── README.md
```

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘O       | Open Folder… |
| ⌘S       | Save current file |
| ⌘1       | Preview mode |
| ⌘2       | Split mode |
| ⌘3       | Edit mode |

## Contributing

PRs welcome. To get started:

1. Fork and clone
2. `swift build` to verify the build works
3. `swift run` to launch
4. Make your change, then run `swift build` again

Style: follow the surrounding code, no new dependencies without discussion, keep the app single-window and keyboard-friendly.

## License

MIT — see [LICENSE](LICENSE). Bundled `marked.min.js` is MIT; `purify.min.js` is Apache-2.0 OR MPL-2.0.
