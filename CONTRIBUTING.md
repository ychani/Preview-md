# Contributing to PreviewMD

Thanks for helping out. Bug reports, small fixes, and focused improvements are all welcome.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Security issues go through [SECURITY.md](SECURITY.md), not public issues.
- By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Requirements

- macOS 13 or later, Swift 5.9+
- **Full Xcode** for `swift test` (XCTest) and for the default universal (arm64 + x86_64) `make app`, which goes through Xcode's build system
- **Command Line Tools** are enough for `swift build`, `swift run PreviewMD`, and a single-architecture app: `make app ARCHS=arm64`

## Build and test

```bash
git clone https://github.com/ychani/Preview-md.git
cd Preview-md
swift build                # debug build
swift run PreviewMD        # launch the app (make run)
swift test                 # unit tests (make test; needs full Xcode)
make app                   # universal, ad-hoc-signed dist/PreviewMD.app with the Quick Look extension
make app ARCHS=arm64       # single-arch app (Command Line Tools are enough)
make install-ql            # build, copy to ~/Applications, register Quick Look
```

Other targets: `make build` (release binaries only), `make appex` (assemble only the Quick Look extension into an existing `dist/` app, unsigned), `make clean`.

`make install-ql` also removes an old `~/Applications/Preview-MD.app`, but only if its bundle ID is `com.preview-md.app`.

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the release build, the tests, and a universal `make app` on every push to `develop` and `main` and on every pull request. It fails unless the app and Quick Look executables contain both `arm64` and `x86_64`.

### Running a source build

Builds from source are **ad-hoc signed** and not notarized. The first time macOS blocks one, open **System Settings → Privacy & Security**, find the message about PreviewMD, and click **Open Anyway**. On macOS 15+, right-click → Open no longer bypasses Gatekeeper.

## Project layout

```
Package.swift                 SPM manifest: MdReaderCore, MdReader (PreviewMD), MdReaderQL (PreviewMD-QL)
Sources/
  MdReaderCore/               shared library
    MarkdownDocumentIO.swift      encoding-, BOM- and line-ending-aware reading/writing
    MarkdownRenderBridge.swift    safe JS call builder for the WebView, CSP, local image/link resolution
    MarkdownHTMLRenderer.swift    static HTML rendering via JavaScriptCore (Quick Look)
    LocalImageInliner.swift       inlines local images into Quick Look previews (same path policy)
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

## Pull requests

- Branch from `develop` and target `develop` with your PR.
- Keep PRs small and about one thing; split unrelated changes.
- Add or update tests in `Tests/MdReaderCoreTests` when you change `MdReaderCore`.
- Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
- Follow the surrounding code style. No new dependencies without discussion first.
- Keep the app private by design: no analytics, telemetry, or network requests of its own.
- Updating a bundled JavaScript library? Update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) too.

## Releasing (maintainers)

`make release` builds, signs, notarizes, and staples the app, packages it into a DMG that is itself signed, notarized, and stapled, and creates a **draft** GitHub release (`v<version>`) whose notes are this version's section of [CHANGELOG.md](CHANGELOG.md). Review and publish the draft on GitHub. It needs:

- `SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"`
- a notarytool keychain profile named `previewmd` (`xcrun notarytool store-credentials previewmd …`; override with `NOTARY_PROFILE`)
- the `gh` CLI, authenticated

The version comes from `CFBundleShortVersionString` in `packaging/Info.plist`. Individual steps: `make notarize-app`, `make dmg`, `make notarize`, `make release-notes`. See the Distribution section of the [Makefile](Makefile).

After publishing, update the Homebrew cask: in [packaging/homebrew/previewmd.rb](packaging/homebrew/previewmd.rb), bump `version` and set `sha256` to the output of `shasum -a 256 dist/PreviewMD-<version>.dmg`, then copy it to `Casks/previewmd.rb` in the `ychani/homebrew-tap` repository.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
