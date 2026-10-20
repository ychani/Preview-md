# Changelog

All notable changes to PreviewMD (formerly Preview-MD) are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow semver.

## [Unreleased]

### Changed
- **Renamed to PreviewMD.** The app is now `PreviewMD.app` (executables
  `PreviewMD` / `PreviewMD-QL`, DMG `PreviewMD-<version>.dmg`) with bundle IDs
  `com.narnarlabs.previewmd` and `com.narnarlabs.previewmd.quicklook`. Remove an
  old `Preview-MD.app`; `make install-ql` does this for `~/Applications`
  automatically when the old bundle ID matches.
- **Universal binary** — the app and Quick Look extension now run natively on
  both Apple silicon and Intel Macs.
- PreviewMD no longer registers itself as a handler for every plain-text file;
  it opens Markdown (`.md`, `.markdown`) only.
- The Markdown file type is now *imported* rather than exported, so PreviewMD
  no longer claims ownership of `net.daringfireball.markdown`.
- Added copyright and app-category metadata; `CFBundleVersion` is now a
  monotonically increasing build number (commit count).

### Fixed
- Opening a Markdown file from Finder (or `open -a PreviewMD file.md`) while
  PreviewMD is running now loads it into the existing window instead of
  opening an extra, duplicate window.

### Build
- `make app` builds universally (`ARCHS=arm64` for a Command-Line-Tools-only
  build) and signs inside-out — Quick Look extension (with its entitlements),
  then app — with hardened runtime, ad-hoc by default (`SIGN_IDENTITY`).
- Release pipeline notarizes and staples the **app** before packaging it, then
  builds the DMG from a staging folder with an `Applications` shortcut, signs,
  notarizes, and staples the DMG, and checks both with `spctl`. Notarization
  fails early with a clear message when signing is ad-hoc or the `previewmd`
  notarytool profile is missing, and fails unless Apple returns *Accepted*.
- `make release` uses only the current version's CHANGELOG section as release
  notes (`dist/RELEASE_NOTES.md`) and creates a draft GitHub release.
- `make install-ql` keeps the build's signature instead of re-signing ad-hoc.

### Docs
- README: consistent PreviewMD naming, Gatekeeper guidance for notarized
  releases vs. source builds (System Settings → Privacy & Security → Open
  Anyway), upgrade/uninstall notes for the old Preview-MD, corrected
  Command Line Tools vs. Xcode requirements, license pointer to
  THIRD_PARTY_NOTICES.md.

## [0.3.0] — 2026-07-19

### Added
- **External-change watching** — the preview reloads automatically when the open
  file is modified by another app (editor workflow), as long as there are no
  unsaved in-app edits.
- **Save conflict guard** — ⌘S detects when the file changed on disk since it
  was opened and offers Overwrite / Reload / Cancel instead of silently
  clobbering the other writer.
- **Quit guard** — quitting with unsaved edits now prompts to save or discard.
- **Encoding detection** — non-UTF-8 files (UTF-16, Latin-1, CP-1252, Shift-JIS)
  open correctly and save back in their original encoding; undecodable files
  show an error instead of a blank document. Applies to Quick Look previews too.
- Unit tests for the JS render bridge and document IO; GitHub Actions CI.
- `make sign` / `make dmg` / `make notarize` / `make release` targets for
  Developer ID distribution.

### Changed
- Folders now load lazily — opening a large folder no longer reads every file
  up front.
- `mermaid.min.js` (~3 MB) is loaded on demand, only for documents containing a
  mermaid block — faster startup and Quick Look previews.
- Rendering now **fails closed**: if the DOMPurify sanitizer is unavailable,
  content is shown as escaped plain text instead of unsanitized HTML.
- Folder-open errors (e.g. permission denied) are reported instead of showing
  an empty sidebar.

## [0.2.0] — 2026-07-14

- Preview-style sidebar, drag-to-open, Dock drops, Open Recent
- Table of contents panel, Mermaid diagrams, find bar (⌘F)
- App icon, Quick Look extension signing fixes, loading indicator

## [0.1.0] — 2026-07-02

- Initial release: SwiftUI markdown reader with Preview/Split/Edit modes,
  GitHub-style rendering via marked + DOMPurify, Quick Look extension.
