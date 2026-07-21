# Changelog

All notable changes to Preview-MD are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow semver.

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
