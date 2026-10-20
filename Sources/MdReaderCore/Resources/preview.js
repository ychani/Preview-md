// PreviewMD preview shell logic. Loaded via <script src> so the CSP can
// drop script-src 'unsafe-inline'. Swift drives it with evaluateJavaScript
// (render(), scroll requests), which CSP does not restrict.
//
// Everything this script relies on is captured into private variables at
// load time, before any document content exists. Rendered markdown can
// contain elements with arbitrary ids, and named-element access would let
// `<a id="webkit">` or `<a id="mermaid">` shadow window globals (DOM
// clobbering) if we looked them up lazily.
var markedAPI = window.marked || null;
var purifyAPI = window.DOMPurify || null;
var extensionsAPI = window.PreviewMDExtensions || null;
var messageHandlers = (window.webkit && window.webkit.messageHandlers) || null;
var contentEl = document.getElementById('previewmd-root');

if (markedAPI && typeof markedAPI.setOptions === 'function') {
  markedAPI.setOptions({ gfm: true, breaks: false });
}

// ── Wikilinks / front matter (markdown-extensions.js) ─────────
// Swift contract (all optional; call before render(), like setImageBase —
// neither setter re-renders on its own):
//
//   setWikiLinks(map)      map: { "<target>": { path: "<root-relative path>",
//                                              kind: "note" | "image" } | null }
//                          <target> is the text between `[[` (or `![[`) and
//                          the first `#` or `|`, whitespace-trimmed, exactly as
//                          written (a trailing `\` from an escaped table pipe
//                          is dropped). A target that is absent or null renders
//                          as missing (data-state="missing"; a missing-image
//                          placeholder for embeds). setWikiLinks(null) — the
//                          default — means "no resolution available": links
//                          render with data-state="unknown" (styled as normal
//                          links) and image embeds fall back to
//                          document-relative srcs.
//   setImageRootBase(base) `previewmd-local://<token>/` serving the folder the
//                          map's paths are relative to. Null (the default)
//                          falls back to the document's image base, so nothing
//                          changes until Swift provides it.
//
// Clicking (or pressing Enter on) a wikilink posts
// webkit.messageHandlers.openWikiLink.postMessage("<target>" or
// "<target>#<heading>") when that handler exists. `[[#heading]]` links into
// the current document scroll locally instead.
var wikiLinkMap = null;
function setWikiLinks(map) {
  if (!map || typeof map !== 'object') { wikiLinkMap = null; return; }
  var copy = Object.create(null);
  Object.keys(map).forEach(function (key) {
    var v = map[key];
    copy[key] = (v && typeof v === 'object' && typeof v.path === 'string' &&
                 (v.kind === 'note' || v.kind === 'image'))
      ? { path: v.path, kind: v.kind } : null;
  });
  wikiLinkMap = copy;
}
window.setWikiLinks = setWikiLinks;

// Random per-shell token marking the <img> elements the embed renderer
// produces as root-relative. Raw HTML in a document cannot guess it, so it
// cannot widen its own images' reach from the document folder to the root.
var rootRelativeMarker = (function () {
  try {
    var a = new Uint32Array(4);
    window.crypto.getRandomValues(a);
    return Array.prototype.map.call(a, function (n) { return n.toString(36); }).join('');
  } catch (e) {
    return String(Math.random()).slice(2) + String(Date.now());
  }
})();

if (extensionsAPI && markedAPI && typeof extensionsAPI.install === 'function') {
  try {
    extensionsAPI.install(markedAPI, {
      mode: 'app',
      rootRelativeMarker: rootRelativeMarker,
      resolve: function (target) {
        if (wikiLinkMap === null) return undefined;
        return Object.prototype.hasOwnProperty.call(wikiLinkMap, target) ? wikiLinkMap[target] : null;
      }
    });
  } catch (e) {}
}

function canPost(name) {
  try { return !!(messageHandlers && messageHandlers[name]); } catch (e) { return false; }
}

function post(name, body) {
  try {
    if (messageHandlers && messageHandlers[name]) {
      messageHandlers[name].postMessage(body);
    }
  } catch (e) {}
}

// ── Remote images ─────────────────────────────────────────────
// The CSP blocks https: images by default. The app reloads the shell with an
// https:-enabled img-src once the user opts in for a document; read the
// policy actually in force rather than trusting any flag.
var remoteImagesAllowed = (function () {
  var meta = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
  var csp = meta ? (meta.getAttribute('content') || '') : '';
  return /img-src[^;]*\shttps:/.test(csp);
})();

// Attributes whose URLs CSP img-src governs (src, srcset, poster, the legacy
// background attribute, and url() inside style).
var IMAGE_URL_ATTRS = ['src', 'srcset', 'poster', 'background', 'style'];
var REMOTE_URL = /(^|[\s,('"])https?:\/\//i;
var remoteRefCount = 0;

// ── Local images ──────────────────────────────────────────────
// Relative <img src> is rewritten to the app's previewmd-local: scheme,
// which serves image files from the document's folder only (validated again
// in Swift). Set by the app before each render; null in Quick Look or when
// there is no document file, in which case relative images stay blocked.
//
// The base is `previewmd-local://<token>/` plus, optionally, the document's
// folder below the served root (`notes/sub/`, percent-encoded). Relative
// srcs resolve against that folder and may climb with ../ up to — never
// above — the root.
var LOCAL_BASE = /^(previewmd-local:\/\/[a-z0-9-]+\/)((?:[^\/?#\\]+\/)*)$/;
var imageBase = null;
function setImageBase(base) {
  imageBase = (typeof base === 'string' && LOCAL_BASE.test(base)) ? base : null;
}
window.setImageBase = setImageBase;

// Base for root-relative wikilink embeds (see setWikiLinks above).
var imageRootBase = null;
function setImageRootBase(base) {
  imageRootBase = (typeof base === 'string' && /^previewmd-local:\/\/[a-z0-9-]+\/$/.test(base)) ? base : null;
}
window.setImageRootBase = setImageRootBase;

function isRelativeURL(s) {
  return !/^[a-z][a-z0-9+.\-]*:/i.test(s) && !/^[\/\\#]/.test(s);
}

// Resolve against a sentinel root (plus the base's folder path); if the
// result leaves it, the path used ../ to climb out of the served root and is
// refused.
var LOCAL_PROBE_ROOT = '/__previewmd_root__/';
function localImageURL(src, base) {
  var m = base ? LOCAL_BASE.exec(base) : null;
  if (!m) return null;
  var u;
  try { u = new URL(src, 'previewmd-local://probe' + LOCAL_PROBE_ROOT + m[2]); } catch (e) { return null; }
  if (u.protocol !== 'previewmd-local:' || u.host !== 'probe') return null;
  if (u.pathname.indexOf(LOCAL_PROBE_ROOT) !== 0) return null;
  var rel = u.pathname.slice(LOCAL_PROBE_ROOT.length);
  return rel ? m[1] + rel : null;
}

function rewriteLocalImage(node) {
  if (node.nodeName !== 'IMG') return;
  // Wikilink embeds carry the marker: their src is relative to the image
  // root (the opened folder) rather than to the document's own folder.
  var rootRelative = false;
  if (node.hasAttribute('data-previewmd-root-relative')) {
    rootRelative = node.getAttribute('data-previewmd-root-relative') === rootRelativeMarker;
    node.removeAttribute('data-previewmd-root-relative');
  }
  var src = (node.getAttribute('src') || '').trim();
  if (!src || !isRelativeURL(src)) return;
  var local = localImageURL(src, rootRelative ? (imageRootBase || imageBase) : imageBase);
  if (local) {
    node.setAttribute('src', local);
  } else {
    node.removeAttribute('src');
    node.classList.add('previewmd-blocked-image');
  }
}

if (purifyAPI && typeof purifyAPI.addHook === 'function') {
  purifyAPI.addHook('afterSanitizeAttributes', function (node) {
    if (!node.getAttribute) return;
    rewriteLocalImage(node);
    for (var i = 0; i < IMAGE_URL_ATTRS.length; i++) {
      var v = node.getAttribute(IMAGE_URL_ATTRS[i]);
      if (v && REMOTE_URL.test(v)) { remoteRefCount++; break; }
    }
  });
}

var remoteBanner = null;
function updateRemoteBanner(hasRemote) {
  // Only meaningful in the app (Quick Look has no handler to opt in with).
  var show = hasRemote && !remoteImagesAllowed && canPost('loadRemoteImages');
  if (!show) {
    if (remoteBanner) remoteBanner.hidden = true;
    return;
  }
  if (!remoteBanner) {
    remoteBanner = document.createElement('div');
    remoteBanner.className = 'previewmd-remote-banner';
    remoteBanner.setAttribute('role', 'status');
    var label = document.createElement('span');
    label.textContent = 'This document has remote images.';
    var button = document.createElement('button');
    button.type = 'button';
    button.textContent = 'Load remote images';
    button.addEventListener('click', function () {
      button.disabled = true;
      post('loadRemoteImages', true);
    });
    remoteBanner.appendChild(label);
    remoteBanner.appendChild(button);
    document.body.insertBefore(remoteBanner, contentEl);
  }
  remoteBanner.hidden = false;
}

// ── Mermaid ───────────────────────────────────────────────────
// mermaid.min.js is ~3 MB, so it is injected only for documents that
// actually contain a mermaid block.
//
// The API object is captured privately once the script has loaded. Never
// trust `window.mermaid` before that: rendered content can contain
// `<a id="mermaid">`, and named-element access then makes `window.mermaid`
// that element (DOM clobbering).
var mermaidAPI = null;
var mermaidLoad = null;
function ensureMermaid() {
  if (mermaidAPI) return Promise.resolve(mermaidAPI);
  if (!mermaidLoad) {
    mermaidLoad = new Promise(function (resolve) {
      var script = document.createElement('script');
      script.src = 'mermaid.min.js';
      script.onload = function () {
        try {
          var api = window.mermaid;
          if (!api || typeof api.initialize !== 'function' ||
              typeof api.run !== 'function') {
            resolve(null);
            return;
          }
          var isDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
          api.initialize({
            startOnLoad: false,
            securityLevel: 'strict',
            // We show our own error block; don't let Mermaid also draw its
            // "Syntax error" diagram into the page.
            suppressErrorRendering: true,
            theme: isDark ? 'dark' : 'neutral'
          });
          mermaidAPI = api;
          resolve(api);
        } catch (e) { resolve(null); }
      };
      script.onerror = function () { resolve(null); };
      document.head.appendChild(script);
    });
  }
  return mermaidLoad;
}

function transformMermaidBlocks() {
  var blocks = contentEl.querySelectorAll('pre > code.language-mermaid');
  blocks.forEach(function (code) {
    var pre = code.parentElement;
    if (!pre) return;
    var div = document.createElement('div');
    div.className = 'mermaid';
    div.textContent = code.textContent;
    pre.replaceWith(div);
  });
}

function showMermaidError(node, err) {
  var msg = err && err.message ? err.message : String(err);
  node.removeAttribute('data-processed');
  node.textContent = 'Mermaid error: ' + msg;
  node.classList.add('mermaid-error');
}

// Bumped on every render(); in-flight diagram work for an older render bails.
var renderGeneration = 0;

function runMermaid() {
  var nodes = contentEl.querySelectorAll('.mermaid');
  if (!nodes.length) return;
  var generation = renderGeneration;
  ensureMermaid().then(function (api) {
    // The document may have re-rendered while the script was loading.
    if (generation !== renderGeneration) return;
    var current = contentEl.querySelectorAll('.mermaid');
    if (!api) {
      current.forEach(function (n) { showMermaidError(n, 'Mermaid failed to load'); });
      return;
    }
    // mermaid.run() is async: render errors arrive as a rejected Promise,
    // not a synchronous throw. Run one node at a time so a bad diagram only
    // turns its own block into the error UI.
    var chain = Promise.resolve();
    Array.prototype.forEach.call(current, function (node) {
      chain = chain.then(function () {
        if (generation !== renderGeneration || !node.isConnected) return;
        var result;
        try {
          result = api.run({ nodes: [node], suppressErrors: false });
        } catch (e) {
          showMermaidError(node, e);
          return;
        }
        return Promise.resolve(result).catch(function (e) {
          if (generation === renderGeneration) showMermaidError(node, e);
        });
      });
    });
  });
}

// ── Heading ids (GitHub-style slugs) ──────────────────────────
// Same algorithm as github-slugger, so [x](#some-heading) links written for
// GitHub work here: lowercase, drop everything but letters, marks, numbers,
// connector punctuation (_), spaces and hyphens, then spaces -> '-'.
// Duplicates get -1, -2, ... Headings that already carry an id (raw HTML)
// keep it. The TOC uses these ids too.
var SLUG_STRIP = /[^\p{L}\p{M}\p{N}\p{Pc} -]/gu;
function slugify(text) {
  return String(text).toLowerCase().replace(SLUG_STRIP, '').replace(/ /g, '-');
}

function assignHeadingIds() {
  var occurrences = Object.create(null);
  // Reserve the shell's own id so no heading can duplicate it.
  occurrences[contentEl.id] = 0;
  var headings = contentEl.querySelectorAll('h1, h2, h3, h4, h5, h6');
  for (var i = 0; i < headings.length; i++) {
    var h = headings[i];
    if (h.id) {
      if (!(h.id in occurrences)) occurrences[h.id] = 0;
      continue;
    }
    var original = slugify(h.textContent || '') || 'section';
    var slug = original;
    while (slug in occurrences) {
      occurrences[original] = (occurrences[original] || 0) + 1;
      slug = original + '-' + occurrences[original];
    }
    occurrences[slug] = 0;
    h.id = slug;
  }
}

// ── Links ─────────────────────────────────────────────────────
function scrollToFragment(fragment) {
  var id;
  try { id = decodeURIComponent(fragment); } catch (e) { id = fragment; }
  if (!id) { window.scrollTo(0, 0); return; }
  var target = document.getElementById(id);
  if (!target || !contentEl.contains(target)) {
    var named = document.getElementsByName(id);
    target = named.length ? named[0] : null;
  }
  if (target && contentEl.contains(target)) {
    target.scrollIntoView({ block: 'start' });
  }
}

var URL_SCHEME = /^[a-z][a-z0-9+.\-]*:/i;
var MARKDOWN_PATH = /\.(md|markdown)$/i;

// In-document and relative links are handled here; anything with a scheme
// (https:, mailto:, ...) is left to the app's navigation policy.
document.addEventListener('click', function (ev) {
  if (ev.defaultPrevented || ev.button !== 0) return;
  var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;
  if (!a || !contentEl.contains(a)) return;
  var href = (a.getAttribute('href') || '').trim();
  if (href.charAt(0) === '#') {
    ev.preventDefault();
    scrollToFragment(href.slice(1));
    return;
  }
  if (URL_SCHEME.test(href)) return;
  // Relative (or absolute-path) link: never navigate the shell away.
  ev.preventDefault();
  if (href.indexOf('//') === 0) return;
  var path = href.split('#')[0].split('?')[0];
  var decoded;
  try { decoded = decodeURIComponent(path); } catch (e) { decoded = path; }
  if (MARKDOWN_PATH.test(decoded)) {
    post('openLocalFile', href);
  }
  // Other local files (PDFs, source files, ...) stay inert.
}, true);

// Wikilinks are <a> elements without href (see setWikiLinks above).
function activateWikiLink(el) {
  var ref = el.getAttribute('data-wikilink') || '';
  if (ref.charAt(0) === '#') {
    scrollToFragment(slugify(ref.slice(1)));
    return;
  }
  if (ref) post('openWikiLink', ref);
}

function wikiLinkFromEvent(ev) {
  var a = ev.target && ev.target.closest ? ev.target.closest('a.wikilink[data-wikilink]') : null;
  return a && contentEl.contains(a) ? a : null;
}

document.addEventListener('click', function (ev) {
  if (ev.defaultPrevented || ev.button !== 0) return;
  var a = wikiLinkFromEvent(ev);
  if (!a) return;
  ev.preventDefault();
  activateWikiLink(a);
}, true);

document.addEventListener('keydown', function (ev) {
  if (ev.key !== 'Enter' || ev.defaultPrevented) return;
  var a = wikiLinkFromEvent(ev);
  if (!a) return;
  ev.preventDefault();
  activateWikiLink(a);
}, true);

// ── TOC ───────────────────────────────────────────────────────
function extractTOC() {
  var nodes = contentEl.querySelectorAll('h1, h2, h3');
  var entries = [];
  for (var i = 0; i < nodes.length; i++) {
    var el = nodes[i];
    if (!el.id) {
      el.id = 'heading-' + i;
    }
    entries.push({
      level: parseInt(el.tagName.substring(1), 10),
      text: el.innerText || el.textContent || '',
      id: el.id
    });
  }
  post('tocUpdate', entries);
}

// ── Render ────────────────────────────────────────────────────
function render(md) {
  if (!contentEl) return;
  var scrollY = window.scrollY;
  renderGeneration++;
  var text = typeof md === 'string' ? md : String(md == null ? '' : md);
  var html;
  try {
    html = markedAPI ? markedAPI.parse(text) : text;
  } catch (e) {
    html = '<pre>' + String(e) + '</pre>';
  }
  remoteRefCount = 0;
  if (purifyAPI) {
    html = purifyAPI.sanitize(html, {
      ADD_ATTR: ['target'],
      FORBID_TAGS: ['style', 'iframe', 'form', 'object', 'embed'],
      FORBID_ATTR: ['onerror', 'onload', 'onclick']
    });
  } else {
    // Fail closed: without the sanitizer, never inject markup — show the
    // raw markdown as escaped plain text instead.
    var esc = document.createElement('div');
    esc.textContent = text;
    html = '<pre>' + esc.innerHTML + '</pre>';
  }
  contentEl.innerHTML = html;
  updateRemoteBanner(remoteRefCount > 0);

  assignHeadingIds();
  transformMermaidBlocks();
  runMermaid();
  extractTOC();

  window.scrollTo(0, scrollY);
}

window.render = render;
