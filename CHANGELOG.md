# Changelog

All notable changes to PreviewMD (formerly Preview-MD) are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow semver.

## [Unreleased]

### Added
- **Folder explorer** — opening a folder shows every Markdown file in its
  subfolders as a VS Code–style tree (folders first, Finder order). Hidden
  folders, `node_modules`, packages and symlinked folders are skipped; the
  tree is capped at 20,000 files with a notice. The scan reads metadata only,
  so iCloud-evicted files are not downloaded.
- **Live folder updates** via FSEvents — new, deleted and renamed files appear
  within about a second; expanded folders and the selection are kept, the
  selected file is revealed in the tree, and a moved or deleted folder is
  reported without closing the open document.
- Sidebar rows show their full path as a tooltip and have a context menu with
  Reveal in Finder, Copy Path and Copy Relative Path (Remove from List in the
  opened-files list). Opened files show their parent folder, so files with
  the same name can be told apart.
- **Multi-root workspace** — File → Add Folder to Workspace… (⌥⌘O) or the
  sidebar's ＋ menu adds a folder as its own top-level root; Remove Folder
  from Workspace (context menu) takes it out without touching the disk.
  Nested or duplicate folders are refused with a notice naming the clashing
  root. Roots are restored on the next launch (unless something was opened
  at launch). Opening a folder still replaces the workspace; choosing several
  folders in the Open panel, or opening several from Finder or the Dock,
  opens them together.
- ⌘O can select several files or folders at once.
- **Window location** — the title shows the file name with a proxy icon
  (drag-out, ⌘-click path menu) and the subtitle shows its folder. New File
  menu commands: Reveal in Finder (⌥⌘R), Copy Path (⌥⌘C) and Copy Relative
  Path (⇧⌥⌘C, for files inside the workspace).
- **Front matter** — a YAML block at the start of a note renders as a compact
  properties table in the app and Quick Look instead of a stray rule and
  heading. A leading `---` horizontal rule still renders as before.
- **Obsidian wikilinks** — `[[note]]`, `[[note|alias]]`, `[[note#heading]]`
  and `[[folder/note]]` resolve across the whole workspace, Obsidian-style
  (case-insensitive, `.md` implied; ties go to an exact path, then the note's
  own folder, then its workspace root, then the shortest path). Links to
  missing notes are dimmed; clicking a link opens the note (inside the
  workspace it is selected in the tree) and scrolls to the heading.
  Backticked wikilinks stay literal.
- **Image embeds** — `![[image.png]]`, with optional `|width` or
  `|widthxheight` sizes, load from anywhere in the same workspace root,
  including image-only folders such as `attachments/`. Note embeds
  `![[note]]` render as links. Quick Look shows wikilinks and embeds as
  styled text without navigation.
- **Local images and links** — relative images (`./img/pic.png`,
  `../attachments/pic.png`) load as long as they stay inside the workspace
  root (or the document's folder); `[x](#heading)` links scroll within the
  document using GitHub-style heading ids; links to other `.md` files open
  them in PreviewMD without leaving the folder sidebar.
- **Zoom** for the preview and editor: View → Zoom In / Zoom Out / Actual
  Size (⌘+ / ⌘− / ⌘0), remembered across launches.
- **Large files** — files over 5 MB open read-only with a notice; Quick Look
  previews show the first 2 MB with a "Preview truncated" note.
- About PreviewMD shows open-source credits and licenses for bundled
  components.

### Changed
- **Renamed to PreviewMD.** The app is now `PreviewMD.app` (executables
  `PreviewMD` / `PreviewMD-QL`, DMG `PreviewMD-<version>.dmg`) with bundle IDs
  `com.narnarlabs.previewmd` and `com.narnarlabs.previewmd.quicklook`. Remove an
  old `Preview-MD.app`; `make install-ql` does this for `~/Applications`
  automatically when the old bundle ID matches.
- **Universal binary** — the app and Quick Look extension now run natively on
  both Apple silicon and Intel Macs.
- **New app icon.**
- PreviewMD no longer registers itself as a handler for every plain-text file;
  it opens Markdown (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mkdn`) only, and
  the same rule applies to the Open panel, Finder opens and drops.
- The Markdown file type is now *imported* rather than exported, so PreviewMD
  no longer claims ownership of `net.daringfireball.markdown`.
- When the open file changes on disk while you have unsaved edits, PreviewMD
  now asks (Keep My Edits / Reload) instead of silently ignoring the change.
- The last workspace is restored only after launch and only if nothing else
  was opened; a missing or unreadable folder is skipped quietly instead of
  alerting on every launch.
- Added copyright and app-category metadata; `CFBundleVersion` is now a
  monotonically increasing build number (commit count).

### Fixed
- The "Load remote images" banner now appears for every blocked remote image —
  badges inside links or raw HTML blocks, `<picture>`/`srcset`, and CSS
  `url()` — and stays pinned at the top while you scroll.
- Opening a different file starts the preview at the top instead of at the
  previous file's scroll position. Re-rendering the same file (typing in
  Split view, a reload from disk, loading remote images) keeps your place.
- PreviewMD now asks before discarding unsaved edits when you open another
  file or folder, and no longer switches files if saving fails.
- Opening a Markdown file from Finder (or `open -a PreviewMD file.md`) while
  PreviewMD is running now loads it into the existing window instead of
  opening an extra, duplicate window.
- Opening several Markdown files at once from Finder or the Dock lists all of
  them instead of only the last one.
- Saving preserves the file's byte-order mark, UTF-16 byte order and line
  endings (CRLF stays CRLF), via an atomic, coordinated replace that keeps
  permissions and follows symlinks. Binary files (NUL bytes) are refused.
- A file's encoding no longer changes after PreviewMD re-reads its own save
  (e.g. an ASCII-only Latin-1 file flipping to UTF-8).
- The file watcher survives editors' atomic saves and picks the file up again
  after it is deleted and recreated.
- Reading the selected file no longer blocks the UI (e.g. while an
  iCloud-evicted file downloads).
- Dropping the same file twice no longer adds it to the list twice.
- Mermaid render errors are shown on the diagram instead of leaving raw text.
- Quick Look no longer mangles code containing `onX = ...`.
- Accessibility: VoiceOver announces toolbar, sidebar, Find bar and table of
  contents controls by name, and faint text and Mermaid error text meet WCAG
  AA contrast.

### Security
- **Remote images are blocked by default.** A document that references them
  shows a "Load remote images" banner; the opt-in applies to that document
  only and is never saved. The preview uses a non-persistent web data store.
- Strict preview Content-Security-Policy (no inline scripts, no `'self'`,
  which WebKit matches against any URL in `file:` documents); local images
  are served through a sandboxed `previewmd-local:` scheme that serves image
  files only, from inside the workspace root or document folder, with
  traversal and symlink-escape checks.
- Quick Look CSP spells out `script-src 'none'` and adds `base-uri` /
  `form-action 'none'`; its fallback sanitizer is hardened against split
  tags and obfuscated `javascript:` URLs.
- Updated the bundled HTML sanitizer (DOMPurify 3.4.17) and diagram renderer
  (Mermaid 11.16.1) to fix known vulnerabilities.

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
- README: feature list grouped by area (explorer & workspace, Obsidian
  front matter and wikilinks, Quick Look, privacy), full keyboard-shortcut
  table, and an updated project layout.
- README: consistent PreviewMD naming, Gatekeeper guidance for notarized
  releases vs. source builds (System Settings → Privacy & Security → Open
  Anyway), upgrade/uninstall notes for the old Preview-MD, corrected
  Command Line Tools vs. Xcode requirements, license pointer to
  THIRD_PARTY_NOTICES.md.
- README rewritten for public release: install from GitHub Releases or
  Homebrew (`brew install --cask ychani/tap/previewmd`), enabling Quick Look,
  privacy statement, build-from-source and maintainer release steps. Corrects
  the Quick Look description — previews are rendered statically (no
  JavaScript, no Mermaid) and never load remote content.
- Added SECURITY.md (private vulnerability reporting), CONTRIBUTING.md, and
  CODE_OF_CONDUCT.md (Contributor Covenant 2.1).

### Repository
- Removed internal planning documents (`docs/PLAN.md`, `docs/DA_FINDINGS.md`)
  and unused icon concept files; `.claude/` is now git-ignored.
- GitHub issue forms (bug report, feature request), pull request template, and
  security contact links.
- CI now also builds the universal app with `make app` and fails unless the
  app and Quick Look executables contain both `arm64` and `x86_64`.
- Draft Homebrew cask (`packaging/homebrew/previewmd.rb`) for the
  `ychani/homebrew-tap` tap.

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
