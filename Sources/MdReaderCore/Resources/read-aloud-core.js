// PreviewMD Read Aloud — pure helpers for read-aloud.js (no DOM access), kept
// in their own file so the unit tests can run them in JavaScriptCore.
//
// All offsets are UTF-16 code units, which is what JavaScript string indices
// already are (Univocal Connect SPEC §7).
var PreviewMDReadAloudCore = (function () {
  'use strict';

  function clamp(n, lo, hi) { return n < lo ? lo : (n > hi ? hi : n); }
  function isHigh(c) { return c >= 0xD800 && c <= 0xDBFF; }
  function isLow(c) { return c >= 0xDC00 && c <= 0xDFFF; }

  // Never leave an offset between the halves of a surrogate pair.
  function snapToCodePoint(text, i) {
    if (i > 0 && i < text.length && isLow(text.charCodeAt(i)) && isHigh(text.charCodeAt(i - 1))) {
      return i - 1;
    }
    return i;
  }

  function commonPrefixLength(a, b) {
    var n = Math.min(a.length, b.length);
    var i = 0;
    while (i < n && a.charCodeAt(i) === b.charCodeAt(i)) i++;
    return i;
  }

  function commonSuffixLength(a, b, max) {
    var i = 0;
    while (i < max && a.charCodeAt(a.length - 1 - i) === b.charCodeAt(b.length - 1 - i)) i++;
    return i;
  }

  var TERMINAL = /[.!?…。！？]/;
  var CLOSER = /["'”’)\]]/;
  var SPACE = /[ \t ]/;

  // Start of the sentence that contains `pos`, looking back at most
  // `maxBack` units: just after a newline, or after sentence punctuation
  // (optionally followed by a closing quote/bracket) and a space. The text
  // start counts as a boundary. With none in reach, `pos` itself — the
  // server starts at the sentence containing startOffset anyway (§5.4).
  function sentenceStartBefore(text, pos, maxBack) {
    pos = clamp(pos, 0, text.length);
    var limit = Math.max(0, pos - maxBack);
    for (var i = pos; i > limit; i--) {
      var ch = text.charAt(i - 1);
      if (ch === '\n') return i;
      if (SPACE.test(ch) && i >= 2) {
        var j = i - 2;
        if (j > 0 && CLOSER.test(text.charAt(j))) j--;
        if (TERMINAL.test(text.charAt(j))) return i;
      }
    }
    return limit === 0 ? 0 : pos;
  }

  // Where to resume after the document text changed from `oldText` to
  // `newText` while reading at `cur` (the start of the current sentence).
  // Unchanged prefix → same offset; unchanged suffix → shifted by the length
  // difference; the edit touched the current sentence → the start of the
  // sentence around the first changed character.
  function remapOffset(oldText, newText, cur) {
    var oldLen = oldText.length;
    var newLen = newText.length;
    cur = clamp(cur | 0, 0, oldLen);
    var p = commonPrefixLength(oldText, newText);
    var q = commonSuffixLength(oldText, newText, Math.min(oldLen, newLen) - p);
    var r;
    if (cur < p) {
      r = cur;
    } else if (cur >= oldLen - q) {
      r = cur + (newLen - oldLen);
    } else {
      r = sentenceStartBefore(newText, snapToCodePoint(newText, p), 300);
    }
    return snapToCodePoint(newText, clamp(r, 0, newLen));
  }

  // The newlines to append so `text` ends with at least `n` (1 or 2) of them
  // (block separators). Nothing at the very start of the text.
  function separatorFor(text, n) {
    if (!text) return '';
    var have = 0;
    while (have < n && text.charCodeAt(text.length - 1 - have) === 10) have++;
    return '\n\n'.slice(0, Math.max(0, n - have));
  }

  // entries: [{ start, length }] sorted by start, non-overlapping. Index of
  // the last entry starting at or before `offset`, or -1.
  function entryIndexAt(entries, offset) {
    var lo = 0;
    var hi = entries.length - 1;
    var found = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (entries[mid].start <= offset) { found = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return found;
  }

  // The parts of the entries covered by [start, end): [{ index, start, end }]
  // with start/end local to the entry. Separators between entries map to
  // nothing.
  function slicesFor(entries, start, end) {
    var out = [];
    if (!(end > start)) return out;
    var i = entryIndexAt(entries, start);
    if (i < 0) i = 0;
    for (; i < entries.length; i++) {
      var e = entries[i];
      if (e.start >= end) break;
      var a = Math.max(start, e.start) - e.start;
      var b = Math.min(end, e.start + e.length) - e.start;
      if (b > a) out.push({ index: i, start: a, end: b });
    }
    return out;
  }

  // Scroll-follow: the new scrollY that puts a word whose client rect is
  // (top, height) at 40 % of the viewport, or null while its centre is
  // still inside the comfort band (25 %–75 % of the viewport height).
  function followScrollTop(top, height, scrollY, viewportHeight) {
    var centre = top + height / 2;
    if (centre >= viewportHeight * 0.25 && centre <= viewportHeight * 0.75) return null;
    return Math.max(0, Math.round(scrollY + centre - viewportHeight * 0.4));
  }

  // True when the UTF-8 encoding of `text` is longer than `limit` bytes.
  // Cheap bounds first: a UTF-16 unit is 1–3 UTF-8 bytes.
  function exceedsUTF8(text, limit) {
    if (text.length * 3 <= limit) return false;
    if (text.length > limit) return true;
    var bytes = 0;
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (c < 0x80) bytes += 1;
      else if (c < 0x800) bytes += 2;
      else if (isHigh(c) && i + 1 < text.length && isLow(text.charCodeAt(i + 1))) { bytes += 4; i++; }
      else bytes += 3;
      if (bytes > limit) return true;
    }
    return false;
  }

  return {
    remapOffset: remapOffset,
    sentenceStartBefore: sentenceStartBefore,
    separatorFor: separatorFor,
    entryIndexAt: entryIndexAt,
    slicesFor: slicesFor,
    followScrollTop: followScrollTop,
    exceedsUTF8: exceedsUTF8
  };
})();
