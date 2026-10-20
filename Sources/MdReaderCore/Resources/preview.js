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
var messageHandlers = (window.webkit && window.webkit.messageHandlers) || null;
var contentEl = document.getElementById('previewmd-root');

if (markedAPI && typeof markedAPI.setOptions === 'function') {
  markedAPI.setOptions({ gfm: true, breaks: false });
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

if (purifyAPI && typeof purifyAPI.addHook === 'function') {
  purifyAPI.addHook('afterSanitizeAttributes', function (node) {
    if (!node.getAttribute) return;
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

  transformMermaidBlocks();
  runMermaid();
  extractTOC();

  window.scrollTo(0, scrollY);
}

window.render = render;
