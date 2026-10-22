// PreviewMD Read Aloud — the page half of the Univocal Connect client.
//
// Univocal speaks; this script turns the rendered document into the text it
// reads, and paints the word and sentence it reports (UTF-16 offsets into
// that text, SPEC §7). Swift (ReadAloudController) owns the session and
// drives this script with evaluateJavaScript; replies and events go back
// through webkit.messageHandlers.readAloud:
//
//   { kind: "ready", highlightMode }                         once at load
//   { kind: "text", text, generation, request, utf16Length, startOffset }
//                                                            reply to requestText
//   { kind: "textChanged", text, startOffset, generation, utf16Length }
//                                                            the document changed mid-session
//   { kind: "seek", offset }                                 click-to-seek
//   { kind: "error", code: "noContent" | "tooLarge", request? }
//
// Swift → JS (window.PreviewMDReadAloud): requestText(request[, { prefer }]), activate(
// { generation } | { text, word, sentence }), apply({ word, sentence }),
// clear(), deactivate(). Ranges are [start, end] arrays or null.
//
// Inert unless the app registered the readAloud handler (Quick Look never
// loads this shell, and nothing here is shared with markdown-extensions.js),
// and inert in the app until activate(): no DOM changes, no messages besides
// `ready`. Highlights never touch the sanitized markup: the CSS Custom
// Highlight API paints ranges without changing the DOM; only the fallback
// for older WebKit (macOS 13, Safari < 17.2) wraps text in <mark>, and it
// puts the original text nodes back exactly as they were.
//
// Like preview.js, everything used later is captured at load, before any
// document content exists (DOM clobbering: rendered content can contain
// elements with arbitrary ids and names).
(function () {
  'use strict';

  var win = window;
  var doc = document;
  var handler = null;
  try {
    handler = (win.webkit && win.webkit.messageHandlers && win.webkit.messageHandlers.readAloud) || null;
  } catch (e) { handler = null; }
  var core = win.PreviewMDReadAloudCore || null;
  var root = doc.getElementById('previewmd-root');
  if (!handler || !core || !root) return;

  var createRange = Document.prototype.createRange;
  var createElement = Document.prototype.createElement;
  var createTextNode = Document.prototype.createTextNode;
  var caretRangeFromPoint = Document.prototype.caretRangeFromPoint || null;
  var hasAttribute = Element.prototype.hasAttribute;
  var getAttribute = Element.prototype.getAttribute;
  var getSelection = win.getSelection;
  var rangeRect = Range.prototype.getBoundingClientRect;
  var comparePoint = Range.prototype.comparePoint;
  var scrollTo = win.scrollTo;
  var setTimer = win.setTimeout;
  var clearTimer = win.clearTimeout;
  var HighlightAPI = typeof win.Highlight === 'function' ? win.Highlight : null;
  var highlightRegistry = (win.CSS && win.CSS.highlights) || null;
  var reducedMotion = (function () {
    try { return win.matchMedia('(prefers-reduced-motion: reduce)'); } catch (e) { return null; }
  })();
  var now = Date.now;

  var MAX_TEXT_BYTES = 8 * 1024 * 1024;   // Univocal's default limits.maxTextBytes
  var WORD = 'univocal-word';
  var SENTENCE = 'univocal-sentence';

  var mode = (HighlightAPI && highlightRegistry && typeof highlightRegistry.set === 'function')
    ? 'css-highlight' : 'mark';

  function post(body) {
    try { handler.postMessage(body); } catch (e) {}
  }

  // ── Text extraction ───────────────────────────────────────────
  // The text Univocal reads is the rendered document's text nodes, verbatim
  // (no whitespace collapsing, so offsets map straight back), with "\n\n"
  // after blocks and "\n" after table cells and <br> — SPEC §7 makes them
  // sentence boundaries, so headings and list items without punctuation do
  // not run into the next block. Separators map to no node.

  // Not read: code blocks (reading code aloud is noise), diagrams, images
  // (alt text is usually a file name, and there is no text to highlight),
  // front matter (metadata), form controls and anything hidden.
  var SKIP_TAGS = {
    pre: 1, script: 1, style: 1, template: 1, img: 1, svg: 1, math: 1, noscript: 1,
    video: 1, audio: 1, canvas: 1, iframe: 1, object: 1, embed: 1,
    input: 1, button: 1, select: 1, textarea: 1
  };
  var SKIP_CLASSES = ['mermaid', 'front-matter', 'wikilink-missing-image'];

  // Newlines after an element (also after a skipped one, so the text on
  // either side of a code block stays apart).
  var BREAK_AFTER = {
    p: 2, h1: 2, h2: 2, h3: 2, h4: 2, h5: 2, h6: 2, li: 2, blockquote: 2, dt: 2, dd: 2,
    figcaption: 2, tr: 2, hr: 2, summary: 2, pre: 2, div: 2, section: 2, article: 2,
    aside: 2, header: 2, footer: 2, nav: 2, figure: 2, table: 2, thead: 2, tbody: 2,
    tfoot: 2, caption: 2, ul: 2, ol: 2, dl: 2, details: 2, address: 2, main: 2,
    td: 1, th: 1, br: 1
  };

  // Whitespace-only text that contains a newline directly inside these is
  // markup formatting (marked puts "\n" between block tags), not content.
  var BLOCK_CONTAINERS = {
    article: 1, ul: 1, ol: 1, dl: 1, table: 1, thead: 1, tbody: 1, tfoot: 1, tr: 1,
    blockquote: 1, details: 1, section: 1, figure: 1
  };
  var FORMATTING_WHITESPACE = /^[ \t\r\n]*\n[ \t\r\n]*$/;

  function isSkipped(el) {
    if (SKIP_TAGS[el.localName] === 1) return true;
    if (hasAttribute.call(el, 'hidden')) return true;
    if (getAttribute.call(el, 'aria-hidden') === 'true') return true;
    var cls = el.classList;
    if (cls && cls.length) {
      for (var i = 0; i < SKIP_CLASSES.length; i++) {
        if (cls.contains(SKIP_CLASSES[i])) return true;
      }
    }
    return false;
  }

  // Returns { text, entries: [{ node, start, length }], index: Map(node → i) }.
  function extract() {
    clearHighlights();
    var out = { text: '', entries: [], index: new Map() };
    visit(root, out);
    return out;
  }

  function visit(parent, out) {
    for (var child = parent.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 3) {
        var data = child.data;
        if (!data) continue;
        if (BLOCK_CONTAINERS[parent.localName] === 1 && FORMATTING_WHITESPACE.test(data)) continue;
        out.index.set(child, out.entries.length);
        out.entries.push({ node: child, start: out.text.length, length: data.length });
        out.text += data;
      } else if (child.nodeType === 1) {
        var name = child.localName;
        if (!isSkipped(child)) {
          if (name === 'details' && !hasAttribute.call(child, 'open')) {
            visitClosedDetails(child, out);
          } else {
            visit(child, out);
          }
        }
        var n = BREAK_AFTER[name];
        if (n) out.text += core.separatorFor(out.text, n);
      }
    }
  }

  // A closed <details> shows only its <summary>.
  function visitClosedDetails(details, out) {
    for (var child = details.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 1 && child.localName === 'summary' && !isSkipped(child)) {
        visit(child, out);
        out.text += core.separatorFor(out.text, 2);
      }
    }
  }

  // ── Session state ─────────────────────────────────────────────
  var generationCounter = 0;
  var lastExtraction = null;      // the latest text sent to Swift, with its node map
  var renderCount = 0;
  var active = false;
  var baseline = null;            // the session's text: { text, entries, index, renderCount }
  var stale = false;              // the DOM no longer matches baseline (edit pending)
  var awaitingRestart = false;    // textChanged posted; Swift restarts the session
  var changeTimer = null;
  var lastWord = null;
  var lastSentence = null;
  var painted = false;

  function remember(extraction) {
    extraction.generation = ++generationCounter;
    extraction.renderCount = renderCount;
    lastExtraction = extraction;
    return extraction;
  }

  // Posts the text for a session (or why there is none). Returns false when
  // it posted an error instead.
  function checkText(text, request) {
    if (!/\S/.test(text)) {
      post({ kind: 'error', code: 'noContent', request: request });
      return false;
    }
    if (core.exceedsUTF8(text, MAX_TEXT_BYTES)) {
      post({ kind: 'error', code: 'tooLarge', request: request });
      return false;
    }
    return true;
  }

  // `opts.prefer` (Univocal's hotkey, SPEC §5.11/§16.12) also picks where
  // to start: "selection" → the start of a selection in the document, else
  // (and for "document") the first fully visible block. Without it (the
  // app's own Read Aloud command) reading starts at the top.
  function requestText(request, opts) {
    var prefer = opts && (opts.prefer === 'selection' || opts.prefer === 'document') ? opts.prefer : null;
    // Before extract(): it puts <mark> pieces back, which may hold the selection.
    var anchor = prefer === 'selection' ? selectionStart() : null;
    var x = remember(extract());
    var startOffset = 0;
    if (prefer) {
      var s = anchor ? pointOffset(x, anchor.node, anchor.offset) : null;
      startOffset = s !== null ? s : firstVisibleOffset(x);
    }
    if (active && baseline) repaint(false);
    if (!checkText(x.text, request)) return;
    post({ kind: 'text', text: x.text, generation: x.generation, request: request,
           utf16Length: x.text.length, startOffset: startOffset });
  }

  // ── Where a hotkey read starts ────────────────────────────────
  // The start of a non-empty selection inside the document, as a boundary
  // point outside any <mark> piece; null without one.
  function selectionStart() {
    var sel = getSelection.call(win);
    if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
    var r = sel.getRangeAt(0);
    if (!root.contains(r.startContainer)) return null;
    return originalPoint(r.startContainer, r.startOffset);
  }

  function originalPoint(node, offset) {
    var origin = pieceOrigin.get(node);
    if (origin) return { node: origin.node, offset: offset + origin.base };
    return { node: node, offset: offset };
  }

  // The offset of a boundary point in `x`: exact inside an extracted text
  // node; otherwise (an element boundary, a skipped code block) the start of
  // the first extracted text after the point. Null when nothing follows.
  function pointOffset(x, node, offset) {
    var exact = textOffset(x, node, offset);
    if (exact !== null) return exact;
    if (!node || !root.contains(node)) return null;
    var at = createRange.call(doc);
    try { at.setStart(node, offset); } catch (e) { return null; }
    var i = core.lowerBound(x.entries.length, function (k) {
      return comparePoint.call(at, x.entries[k].node, 0) >= 0;
    });
    return i < x.entries.length ? x.entries[i].start : null;
  }

  // The start of the first fully visible block: candidates are the text
  // nodes that begin a block or line (offset 0 or right after a separator
  // newline), measured lazily from the first one that is not above the
  // viewport. 0 when nothing is visible.
  function firstVisibleOffset(x) {
    var starts = [];
    for (var i = 0; i < x.entries.length; i++) {
      var s = x.entries[i].start;
      if (s === 0 || x.text.charCodeAt(s - 1) === 10) starts.push(i);
    }
    if (!starts.length) return 0;
    var height = win.innerHeight;
    var rects = [];
    function rectOf(k) {
      if (rects[k] === undefined) {
        var r = createRange.call(doc);
        r.selectNodeContents(x.entries[starts[k]].node);
        rects[k] = rangeRect.call(r);
      }
      return rects[k];
    }
    var first = core.lowerBound(starts.length, function (k) { return rectOf(k).bottom > 0; });
    var tops = [];
    var bottoms = [];
    for (var k = first; k < starts.length; k++) {
      var rect = rectOf(k);
      tops.push(rect.top);
      bottoms.push(rect.bottom);
      if (rect.top >= height) break;
    }
    var v = core.firstVisibleIndex(tops, bottoms, height);
    return v < 0 ? 0 : x.entries[starts[first + v]].start;
  }

  function normRange(r) {
    if (!r || typeof r.length !== 'number' || r.length < 2) return null;
    var s = Number(r[0]);
    var e = Number(r[1]);
    if (!isFinite(s) || !isFinite(e) || s < 0 || e <= s) return null;
    return [s, e];
  }

  function sameRange(a, b) {
    return a === b || (!!a && !!b && a[0] === b[0] && a[1] === b[1]);
  }

  function cancelChange() {
    if (changeTimer !== null) { clearTimer.call(win, changeTimer); changeTimer = null; }
  }

  // Starts highlighting for a session. `{ generation }`: the text posted by
  // requestText / textChanged with that generation. `{ text, word, sentence }`:
  // re-attach to a running session after the page reloaded (a new shell in
  // the same or another web view); compared with the document once it has
  // rendered, like any re-render.
  function activate(opts) {
    opts = opts || {};
    cancelChange();
    active = true;
    stale = false;
    awaitingRestart = false;
    painted = false;
    lastWord = null;
    lastSentence = null;
    if (typeof opts.text === 'string') {
      baseline = { text: opts.text, entries: [], index: new Map(), renderCount: -1 };
      lastWord = normRange(opts.word);
      lastSentence = normRange(opts.sentence);
      if (renderCount > 0) sync();
      return;
    }
    if (lastExtraction && lastExtraction.generation === opts.generation) {
      baseline = lastExtraction;
      if (baseline.renderCount !== renderCount) sync();
    } else {
      // Not this page's text (the page reloaded since): wait for Swift's
      // re-attach, which follows the new page's `ready`.
      baseline = null;
    }
  }

  function deactivate() {
    cancelChange();
    clearHighlights();
    active = false;
    baseline = null;
    stale = false;
    awaitingRestart = false;
    lastWord = null;
    lastSentence = null;
  }

  function apply(update) {
    if (!active || awaitingRestart) return;
    var word = normRange(update && update.word);
    var sentence = normRange(update && update.sentence);
    var follow = !sameRange(word, lastWord) || (!word && !sameRange(sentence, lastSentence));
    // Univocal may repeat a word range (one token spoken as several words).
    if (painted && sameRange(word, lastWord) && sameRange(sentence, lastSentence)) return;
    lastWord = word;
    lastSentence = sentence;
    if (stale || !baseline) return;
    repaint(follow);
  }

  function clear() {
    clearHighlights();
  }

  // ── Re-render during a session ────────────────────────────────
  // render() replaces the whole document, so highlights and the node map are
  // gone after an edit (Split view) or a reload from disk. Same text: map
  // again and repaint. Different text: after a 400 ms pause in typing, tell
  // Swift to restart reading from the remapped current sentence.
  doc.addEventListener('previewmd:rendered', function () {
    renderCount++;
    wraps = [];        // the marks went away with the old content
    painted = false;
    programmaticScrollUntil = now() + 300;   // render() restores the scroll offset
    if (active && baseline) sync();
  });

  function sync() {
    var x = extract();
    if (x.text === baseline.text) {
      cancelChange();
      baseline.entries = x.entries;
      baseline.index = x.index;
      baseline.renderCount = renderCount;
      stale = false;
      if (!awaitingRestart) repaint(false);
      return;
    }
    stale = true;
    cancelChange();
    changeTimer = setTimer.call(win, postChange, 400);
  }

  function postChange() {
    changeTimer = null;
    if (!active || !baseline) return;
    var x = extract();
    if (x.text === baseline.text) {
      baseline.entries = x.entries;
      baseline.index = x.index;
      baseline.renderCount = renderCount;
      stale = false;
      if (!awaitingRestart) repaint(false);
      return;
    }
    var cur = lastSentence ? lastSentence[0] : (lastWord ? lastWord[0] : 0);
    var startOffset = core.remapOffset(baseline.text, x.text, cur);
    baseline = remember(x);
    stale = false;
    awaitingRestart = true;
    lastWord = null;
    lastSentence = null;
    if (!checkText(x.text, null)) return;
    post({ kind: 'textChanged', text: x.text, startOffset: startOffset,
           generation: x.generation, utf16Length: x.text.length });
  }

  // ── Painting ──────────────────────────────────────────────────
  function repaint(follow) {
    if (!baseline) return;
    var ws = lastWord ? core.slicesFor(baseline.entries, lastWord[0], lastWord[1]) : [];
    var ss = lastSentence ? core.slicesFor(baseline.entries, lastSentence[0], lastSentence[1]) : [];
    var target;
    if (mode === 'css-highlight') {
      var sentenceRange = paintHighlight(SENTENCE, ss, 0);
      var wordRange = paintHighlight(WORD, ws, 1);
      target = wordRange || sentenceRange;
    } else {
      clearMarks();
      target = paintMarks(ss, ws);
    }
    painted = true;
    if (follow && target) followTo(target);
  }

  function clearHighlights() {
    if (mode === 'css-highlight') {
      try {
        highlightRegistry.delete(WORD);
        highlightRegistry.delete(SENTENCE);
      } catch (e) {}
    } else {
      clearMarks();
    }
    painted = false;
  }

  function rangeOf(slice) {
    var node = baseline.entries[slice.index].node;
    var r = createRange.call(doc);
    r.setStart(node, slice.start);
    r.setEnd(node, slice.end);
    return r;
  }

  // One Range per text-node slice, so a sentence that crosses inline
  // elements paints only its text. Returns the first range (scroll target).
  function paintHighlight(name, slices, priority) {
    if (!slices.length) {
      try { highlightRegistry.delete(name); } catch (e) {}
      return null;
    }
    var first = null;
    try {
      var h = new HighlightAPI();
      h.priority = priority;
      for (var i = 0; i < slices.length; i++) {
        var r = rangeOf(slices[i]);
        if (!first) first = r;
        h.add(r);
      }
      highlightRegistry.set(name, h);
    } catch (e) { return null; }
    return first;
  }

  // ── <mark> fallback ───────────────────────────────────────────
  // Each text node with highlighted parts is swapped for pieces (plain text
  // and <mark> elements); clearMarks() puts the original node back. Node
  // identity and the document text therefore never change, and the node map
  // from extract() stays valid. Pieces remember where they came from so a
  // click inside a mark still maps to an offset.
  var wraps = [];                 // [{ node, pieces }]
  var pieceOrigin = new WeakMap(); // piece text node → { node, base }

  function clearMarks() {
    for (var i = wraps.length - 1; i >= 0; i--) {
      var w = wraps[i];
      var first = w.pieces[0];
      var parent = first && first.parentNode;
      if (!parent) continue;
      parent.insertBefore(w.node, first);
      for (var j = 0; j < w.pieces.length; j++) {
        if (w.pieces[j].parentNode === parent) parent.removeChild(w.pieces[j]);
      }
    }
    wraps = [];
  }

  // flags: 1 = sentence, 2 = word. Returns the first word mark (else the
  // first sentence mark) as the scroll target.
  function paintMarks(sentenceSlices, wordSlices) {
    var spans = new Map();   // entry index → [{ start, end, flag }]
    function add(slices, flag) {
      for (var i = 0; i < slices.length; i++) {
        var s = slices[i];
        if (!spans.has(s.index)) spans.set(s.index, []);
        spans.get(s.index).push({ start: s.start, end: s.end, flag: flag });
      }
    }
    add(sentenceSlices, 1);
    add(wordSlices, 2);
    var firstWord = null;
    var firstSentence = null;
    spans.forEach(function (list, index) {
      var node = baseline.entries[index].node;
      var parent = node.parentNode;
      if (!parent || !root.contains(node)) return;
      var data = node.data;
      var cuts = [0, data.length];
      list.forEach(function (s) { cuts.push(s.start, s.end); });
      cuts.sort(function (a, b) { return a - b; });
      var pieces = [];
      for (var k = 0; k + 1 < cuts.length; k++) {
        var a = cuts[k];
        var b = cuts[k + 1];
        if (b <= a) continue;
        var flags = 0;
        list.forEach(function (s) { if (s.start <= a && s.end >= b) flags |= s.flag; });
        var text = createTextNode.call(doc, data.slice(a, b));
        pieceOrigin.set(text, { node: node, base: a });
        if (!flags) {
          pieces.push(text);
          continue;
        }
        var mark = createElement.call(doc, 'mark');
        mark.className = (flags & 1 ? SENTENCE : '') + (flags === 3 ? ' ' : '') + (flags & 2 ? WORD : '');
        mark.appendChild(text);
        pieces.push(mark);
        if ((flags & 2) && !firstWord) firstWord = mark;
        if (!firstSentence) firstSentence = mark;
      }
      for (var p = 0; p < pieces.length; p++) parent.insertBefore(pieces[p], node);
      parent.removeChild(node);
      wraps.push({ node: node, pieces: pieces });
    });
    return firstWord || firstSentence;
  }

  // ── Scroll-follow ─────────────────────────────────────────────
  // Keep the spoken word in a comfort band; a manual scroll (wheel, touch,
  // scrolling keys, or any scroll we did not start) suspends this for 4 s.
  var programmaticScrollUntil = 0;
  var userScrolledUntil = 0;

  function followTo(target) {
    if (now() < userScrolledUntil) return;
    var rect;
    try { rect = target.getBoundingClientRect(); } catch (e) { return; }
    if (!rect || (rect.width === 0 && rect.height === 0)) return;
    var top = core.followScrollTop(rect.top, rect.height, win.scrollY, win.innerHeight);
    if (top === null) return;
    programmaticScrollUntil = now() + 800;
    var smooth = !(reducedMotion && reducedMotion.matches);
    scrollTo.call(win, { top: top, behavior: smooth ? 'smooth' : 'auto' });
  }

  function userScrolled() {
    if (active) userScrolledUntil = now() + 4000;
  }

  var SCROLL_KEYS = {
    PageUp: 1, PageDown: 1, ArrowUp: 1, ArrowDown: 1, Home: 1, End: 1, ' ': 1, Spacebar: 1
  };
  win.addEventListener('wheel', userScrolled, { passive: true, capture: true });
  win.addEventListener('touchmove', userScrolled, { passive: true, capture: true });
  win.addEventListener('keydown', function (ev) {
    if (SCROLL_KEYS[ev.key] === 1) userScrolled();
  }, true);
  win.addEventListener('scroll', function () {
    var t = now();
    if (t < programmaticScrollUntil) {
      // Our smooth scroll is still moving.
      programmaticScrollUntil = Math.max(programmaticScrollUntil, t + 150);
      return;
    }
    userScrolled();
  }, { passive: true });

  // ── Click-to-seek ─────────────────────────────────────────────
  // While reading, a plain click on document text moves reading there.
  // Links, controls, wikilinks and text selection keep their usual meaning.
  var INTERACTIVE = 'a, button, input, select, textarea, label, summary, .wikilink';

  // The offset of (node, offset) in extraction `x` when node is one of its
  // text nodes (or a <mark> piece of one); else null.
  function textOffset(x, node, offset) {
    if (!x || !node || node.nodeType !== 3) return null;
    var p = originalPoint(node, offset);
    var i = x.index.get(p.node);
    if (i === undefined) return null;
    var e = x.entries[i];
    return e.start + Math.max(0, Math.min(p.offset, e.length));
  }

  doc.addEventListener('click', function (ev) {
    if (!active || stale || awaitingRestart || !baseline || !caretRangeFromPoint) return;
    if (ev.defaultPrevented || ev.button !== 0 ||
        ev.metaKey || ev.ctrlKey || ev.altKey || ev.shiftKey) return;
    var target = ev.target;
    if (!target || !target.closest || !root.contains(target) || target.closest(INTERACTIVE)) return;
    var sel = getSelection.call(win);
    if (sel && !sel.isCollapsed) return;
    var caret = caretRangeFromPoint.call(doc, ev.clientX, ev.clientY);
    if (!caret) return;
    var offset = textOffset(baseline, caret.startContainer, caret.startOffset);
    if (offset !== null) post({ kind: 'seek', offset: offset });
  }, false);

  // ── API ───────────────────────────────────────────────────────
  var api = {
    requestText: requestText,
    activate: activate,
    deactivate: deactivate,
    apply: apply,
    clear: clear,
    // QA and tests: exercise the <mark> fallback on a WebKit that has the
    // Highlight API.
    forceMarkMode: function () {
      clearHighlights();
      mode = 'mark';
      if (active && baseline) repaint(false);
    }
  };
  Object.defineProperty(api, 'highlightMode', { get: function () { return mode; } });
  Object.defineProperty(win, 'PreviewMDReadAloud', { value: api, writable: false, configurable: false });

  post({ kind: 'ready', highlightMode: mode });
})();
