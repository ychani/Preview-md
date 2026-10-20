// PreviewMD preview shell logic. Loaded via <script src> so the CSP can
// drop script-src 'unsafe-inline'. Swift drives it with evaluateJavaScript
// (render(), scroll requests), which CSP does not restrict.
(function () {
  if (window.marked && typeof marked.setOptions === "function") {
    marked.setOptions({ gfm: true, breaks: false });
  }
})();

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
  var blocks = document.querySelectorAll('#content pre > code.language-mermaid');
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
  var nodes = document.querySelectorAll('#content .mermaid');
  if (!nodes.length) return;
  var generation = renderGeneration;
  ensureMermaid().then(function (api) {
    // The document may have re-rendered while the script was loading.
    if (generation !== renderGeneration) return;
    var current = document.querySelectorAll('#content .mermaid');
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

function extractTOC() {
  var nodes = document.querySelectorAll('#content h1, #content h2, #content h3');
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
  try {
    if (window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.tocUpdate) {
      window.webkit.messageHandlers.tocUpdate.postMessage(entries);
    }
  } catch (e) {}
}

function render(md) {
  var el = document.getElementById('content');
  if (!el) return;
  var scrollY = window.scrollY;
  renderGeneration++;
  var text = typeof md === "string" ? md : String(md == null ? "" : md);
  var html;
  try {
    html = window.marked ? marked.parse(text) : text;
  } catch (e) {
    html = "<pre>" + String(e) + "</pre>";
  }
  if (window.DOMPurify) {
    html = DOMPurify.sanitize(html, {
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
  el.innerHTML = html;

  transformMermaidBlocks();
  runMermaid();
  extractTOC();

  window.scrollTo(0, scrollY);
}

window.render = render;
