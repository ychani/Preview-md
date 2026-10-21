// PreviewMD markdown extensions for marked: YAML front matter and
// Obsidian-style [[wikilinks]] / ![[embeds]].
//
// DOM-free on purpose: the same file runs in the app's WKWebView (loaded by
// preview.html before preview.js) and in Quick Look's JavaScriptCore context
// (MarkdownHTMLRenderer), where there is no window or document.
//
//   PreviewMDExtensions.install(marked, {
//     mode: 'app' | 'static',
//     // app mode only:
//     resolve: function (target) { ... },  // see resolveTarget below
//     rootRelativeMarker: '<random token>'  // see renderEmbed below
//   });
//
// Every piece of document text is HTML-escaped here. The output still goes
// through DOMPurify (app) or MarkdownHTMLRenderer.sanitize (Quick Look).
var PreviewMDExtensions = (function () {
  'use strict';

  function escapeHTML(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // ── Front matter ────────────────────────────────────────────
  // Only at the very start of the document (an optional BOM aside): opening
  // `---` on line 1, closing `---` or `...` on its own line, and a body with
  // at least one `key:` line. Anything else (a leading thematic break, a
  // setext heading, an unclosed fence) is left to marked untouched.
  var FRONT_MATTER = /^﻿?---[ \t]*\n([\s\S]*?)\n(?:---|\.\.\.)[ \t]*(?:\n|$)/;
  var KEY_LINE = /^([^\s#\-:'"\[\]{}][^:]*?)[ \t]*:(?:[ \t]+(.*?))?[ \t]*$/;
  var LIST_ITEM = /^[ \t]*-(?:[ \t]+(.*?))?[ \t]*$/;
  var BLOCK_SCALAR = /^[|>][+-]?[0-9]?$/;

  function unquote(v) {
    var m;
    if ((m = /^"((?:[^"\\]|\\.)*)"$/.exec(v))) {
      return m[1].replace(/\\(.)/g, function (_, c) {
        return c === 'n' ? '\n' : c === 't' ? '\t' : c;
      });
    }
    if ((m = /^'((?:[^']|'')*)'$/.exec(v))) return m[1].replace(/''/g, "'");
    return null;
  }

  // A plain or quoted scalar; null when it can't be read with this subset.
  function scalar(v) {
    v = v.trim();
    if (v === '') return '';
    var c = v.charAt(0);
    if (c === '"' || c === "'") return unquote(v);
    if (c === '{' || c === '[' || c === '&' || c === '*' || c === '!' || c === '|' || c === '>') return null;
    return v.replace(/[ \t]+#.*$/, '');
  }

  // `[a, "b, c", d]` → ['a', 'b, c', 'd']; null for nested or malformed lists.
  function inlineList(v) {
    v = v.trim();
    if (!/^\[[\s\S]*\]$/.test(v)) return null;
    var body = v.slice(1, -1);
    if (body.trim() === '') return [];
    var items = [];
    var re = /\s*("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^,"'\[\]{}]*?)\s*(,|$)/g;
    var pos = 0;
    while (pos <= body.length) {
      re.lastIndex = pos;
      var m = re.exec(body);
      if (!m || m.index !== pos) return null;
      var item = scalar(m[1]);
      if (item === null) return null;
      items.push(item);
      if (m[2] !== ',') break;
      pos = re.lastIndex;
    }
    return re.lastIndex === body.length ? items : null;
  }

  // Minimal YAML: top-level `key: value` with plain/quoted scalars, inline
  // lists, block lists and block scalars. Each entry is
  //   { key, value: string | string[] }  or  { raw: string } (unparsed lines).
  function parseFrontMatter(body) {
    var lines = body.split('\n');
    var entries = [];
    var i = 0;
    function indented(line) { return /^[ \t]/.test(line); }
    while (i < lines.length) {
      var line = lines[i];
      if (/^\s*(#.*)?$/.test(line)) { i++; continue; }
      var m = indented(line) ? null : KEY_LINE.exec(line);
      if (!m) { entries.push({ raw: line }); i++; continue; }
      var key = m[1];
      var rest = m[2] || '';
      i++;
      // Lines belonging to this key: indented ones, plus `- item` at column 0
      // (YAML allows a block sequence at the key's own indentation).
      var children = [];
      while (i < lines.length &&
             (indented(lines[i]) || /^-([ \t]|$)/.test(lines[i]) || /^\s*$/.test(lines[i]))) {
        children.push(lines[i]);
        i++;
      }
      while (children.length && /^\s*$/.test(children[children.length - 1])) children.pop();

      if (BLOCK_SCALAR.test(rest)) {
        var text = children.map(function (l) { return l.trim(); });
        entries.push({ key: key, value: rest.charAt(0) === '|' ? text.join('\n') : text.join(' ') });
        continue;
      }
      if (rest !== '') {
        var value = rest.charAt(0) === '[' ? inlineList(rest) : scalar(rest);
        if (value === null || children.length) {
          entries.push({ key: key, value: null, raw: [rest].concat(children).join('\n') });
        } else {
          entries.push({ key: key, value: value });
        }
        continue;
      }
      if (!children.length) { entries.push({ key: key, value: '' }); continue; }
      var items = [];
      var ok = true;
      for (var j = 0; j < children.length && ok; j++) {
        if (/^\s*$/.test(children[j])) continue;
        var li = LIST_ITEM.exec(children[j]);
        var item = li ? scalar(li[1] || '') : null;
        if (item === null) ok = false; else items.push(item);
      }
      if (ok) {
        entries.push({ key: key, value: items });
      } else {
        // Nested mapping or something richer: show its lines verbatim.
        entries.push({ key: key, value: null, raw: children.join('\n') });
      }
    }
    return entries;
  }

  function renderValue(entry) {
    if (entry.value === null) return '<code>' + escapeHTML(entry.raw) + '</code>';
    if (Array.isArray(entry.value)) {
      if (!entry.value.length) return '';
      return '<ul class="front-matter-list">' + entry.value.map(function (v) {
        return '<li>' + escapeHTML(v) + '</li>';
      }).join('') + '</ul>';
    }
    return escapeHTML(entry.value);
  }

  function renderFrontMatter(entries) {
    var rows = entries.map(function (e) {
      if (e.key === undefined) {
        return '<tr><td colspan="2"><code>' + escapeHTML(e.raw) + '</code></td></tr>';
      }
      return '<tr><th scope="row">' + escapeHTML(e.key) + '</th><td>' + renderValue(e) + '</td></tr>';
    });
    return '<section class="front-matter"><table><tbody>' + rows.join('') +
      '</tbody></table></section>\n';
  }

  function frontMatterExtension() {
    return {
      name: 'previewmdFrontMatter',
      level: 'block',
      tokenizer: function (src, tokens) {
        // Top level of the document only, before any other token. Nested
        // block contexts (blockquotes, list items) start with an empty token
        // list too, so also require the lexer's own top-level array.
        var lexer = this.lexer;
        if (!lexer || tokens !== lexer.tokens || tokens.length !== 0) return;
        var m = FRONT_MATTER.exec(src);
        if (!m || m[1].trim() === '') return;
        var lines = m[1].split('\n');
        var hasKey = false;
        for (var i = 0; i < lines.length; i++) {
          if (KEY_LINE.test(lines[i])) { hasKey = true; break; }
        }
        if (!hasKey) return;
        return { type: 'previewmdFrontMatter', raw: m[0], entries: parseFrontMatter(m[1]) };
      },
      renderer: function (token) {
        return renderFrontMatter(token.entries);
      }
    };
  }

  // ── Wikilinks ───────────────────────────────────────────────
  // [[target]], [[target#heading]], [[target|alias]], [[target#heading|alias]],
  // and the ![[...]] embed form. Codespans are lexed by marked before inline
  // extensions see their contents, so `[[x]]` in backticks stays literal.
  var WIKILINK = /^(!?)\[\[([^\[\]\n]+?)\]\]/;
  var IMAGE_EXT = /\.(png|jpe?g|gif|webp|svg|bmp|avif|tiff?|ico|heic)$/i;
  var SIZE_ALIAS = /^(\d+)(?:x(\d+))?$/;

  function parseWikiLink(inner) {
    var alias = null;
    var bar = inner.indexOf('|');
    if (bar !== -1) {
      alias = inner.slice(bar + 1).trim();
      inner = inner.slice(0, bar);
    }
    var heading = null;
    var hash = inner.indexOf('#');
    if (hash !== -1) {
      heading = inner.slice(hash + 1).trim();
      inner = inner.slice(0, hash);
    }
    // `[[a\|b]]` outside a table: Obsidian's escaped pipe.
    var target = inner.trim().replace(/\\$/, '').trim();
    if (!target && !heading) return null;
    return { target: target, heading: heading || null, alias: alias || null };
  }

  function basename(path) {
    var parts = path.split('/');
    return parts[parts.length - 1] || path;
  }

  function displayText(link) {
    if (link.alias && !(link.embed && SIZE_ALIAS.test(link.alias))) return link.alias;
    var name = link.target ? basename(link.target) : '';
    if (link.heading) return name ? name + ' › ' + link.heading : link.heading;
    return name;
  }

  // What the link points at, as sent to the app: `target` or `target#heading`.
  function linkRef(link) {
    return link.target + (link.heading ? '#' + link.heading : '');
  }

  function encodePath(path) {
    return path.replace(/^\/+/, '').split('/').map(encodeURIComponent).join('/');
  }

  function wikilinkExtension(options) {
    var mode = options.mode === 'app' ? 'app' : 'static';
    var resolve = typeof options.resolve === 'function' ? options.resolve : null;
    var marker = typeof options.rootRelativeMarker === 'string' ? options.rootRelativeMarker : '';

    // undefined → no map (state "unknown"); null → missing; else {path, kind}.
    function resolveTarget(target) {
      if (!resolve || !target) return undefined;
      var r;
      try { r = resolve(target); } catch (e) { return undefined; }
      if (r === undefined) return undefined;
      if (r && typeof r.path === 'string' && (r.kind === 'note' || r.kind === 'image')) return r;
      return null;
    }

    function renderLink(link, text) {
      if (mode !== 'app') return '<span class="wikilink">' + escapeHTML(text) + '</span>';
      var state = 'resolved';
      if (link.target) {
        var r = resolveTarget(link.target);
        state = r === undefined ? 'unknown' : r === null ? 'missing' : 'resolved';
      }
      return '<a class="wikilink" data-wikilink="' + escapeHTML(linkRef(link)) +
        '" data-state="' + state + '" role="link" tabindex="0">' + escapeHTML(text) + '</a>';
    }

    // Image embed. With a resolved map entry the src is the root-relative path
    // and carries the marker attribute; preview.js resolves it against the
    // image root base. The marker is a random per-session token so raw HTML
    // in a document cannot opt its own <img> into root-relative resolution.
    // Without a map, fall back to a document-relative src (the normal
    // relative-image path).
    //
    // Static mode (Quick Look) has no map: the embed becomes a
    // document-relative <img> marked data-previewmd-embed, which
    // LocalImageInliner (Swift) resolves in the document's folder, then its
    // attachments/, assets/ and images/ subfolders, and inlines as cid:.
    function renderEmbed(link) {
      var alt = link.alias && !SIZE_ALIAS.test(link.alias) ? link.alias : basename(link.target);
      var size = link.alias ? SIZE_ALIAS.exec(link.alias) : null;
      var dims = size ? ' width="' + size[1] + '"' + (size[2] ? ' height="' + size[2] + '"' : '') : '';
      if (mode !== 'app') {
        return '<img src="' + escapeHTML(encodePath(link.target)) + '" alt="' + escapeHTML(alt) + '"' +
          dims + ' data-previewmd-embed="">';
      }
      var r = resolveTarget(link.target);
      if (r === null || (r && r.kind !== 'image')) {
        return '<span class="wikilink-missing-image" title="Image not found">' +
          escapeHTML(link.target) + '</span>';
      }
      if (r === undefined) {
        return '<img src="' + escapeHTML(encodePath(link.target)) + '" alt="' + escapeHTML(alt) + '"' + dims + '>';
      }
      return '<img src="' + escapeHTML(encodePath(r.path)) + '" data-previewmd-root-relative="' +
        escapeHTML(marker) + '" alt="' + escapeHTML(alt) + '"' + dims + '>';
    }

    return {
      name: 'previewmdWikiLink',
      level: 'inline',
      start: function (src) {
        var i = src.indexOf('[[');
        if (i > 0 && src.charAt(i - 1) === '!') i--;
        return i === -1 ? undefined : i;
      },
      tokenizer: function (src) {
        var m = WIKILINK.exec(src);
        if (!m) return;
        // No links inside link text: let marked handle it as plain text.
        if (this.lexer && this.lexer.state && this.lexer.state.inLink) return;
        var link = parseWikiLink(m[2]);
        if (!link) return;
        link.embed = m[1] === '!';
        return { type: 'previewmdWikiLink', raw: m[0], link: link };
      },
      renderer: function (token) {
        var link = token.link;
        if (link.embed && link.target && IMAGE_EXT.test(link.target)) return renderEmbed(link);
        // ![[note]] note embeds render as plain wikilinks for now.
        return renderLink(link, displayText(link));
      }
    };
  }

  // Fenced code blocks: copy the language onto the <pre> as data-lang so
  // preview.css labels the block with just the name ("mermaid", not
  // "language-mermaid"). marked has already escaped the language for the
  // class attribute and the capture stops at the closing quote, so it is
  // re-emitted as-is. <code class="language-…"> is left untouched (the app's
  // Mermaid pass selects on it). Unlabeled fences get no attribute.
  var CODE_BLOCK_OPEN = /<pre><code class="language-([^"\s]+)">/g;

  function labelCodeBlocks(html) {
    return html.replace(CODE_BLOCK_OPEN, function (_, lang) {
      return '<pre data-lang="' + lang + '"><code class="language-' + lang + '">';
    });
  }

  // ── Remote images ───────────────────────────────────────────
  // How many https: image loads one element of the final, sanitized preview
  // DOM would make: exactly what the app's strict CSP blocks and the
  // "Load remote images" opt-in (img-src … https:) unblocks. preview.js runs
  // it over every element after rendering, so images nested in links, inside
  // raw HTML blocks, in <picture>, or in inline styles are all seen no matter
  // which marked token produced them. DOM-free so it runs in JavaScriptCore
  // for tests: `getAttribute(name)` returns the attribute value or null.
  //
  // Only https: counts — the opt-in never allows http:, so a banner for an
  // http:-only document would offer a button that loads nothing.
  var IMAGE_URL_ATTRS_BY_TAG = {
    img: ['src', 'srcset'],
    source: ['srcset'],          // <picture><source srcset>
    input: ['src'],              // <input type="image">
    video: ['poster'],
    image: ['href', 'xlink:href'],   // SVG <image>
    feimage: ['href', 'xlink:href']  // SVG <feImage>
  };

  // URL parsers drop tabs and newlines anywhere and leading C0/space
  // characters, so ` https:` and `ht\ttps:` still load remotely.
  function normalizeURL(v) {
    return String(v).replace(/[\t\n\r]/g, '').replace(/^[\u0000- ]+/, '');
  }

  function isRemoteURL(v) {
    return /^https:/i.test(normalizeURL(v));
  }

  // srcset: comma-separated `url [descriptor]` candidates.
  function srcsetHasRemote(v) {
    return /(?:^|,)\s*https:/i.test(String(v).replace(/[\t\n\r]/g, ' '));
  }

  // Inline style: url(https:…) or a quoted https: string (image-set()),
  // after undoing CSS escapes such as `url(\68ttps://…)`.
  function cssUnescape(s) {
    return String(s).replace(/\\([0-9a-fA-F]{1,6})[ \t\n\r\f]?|\\([^\n\r\f0-9a-fA-F])/g,
      function (_, hex, ch) {
        if (ch !== undefined) return ch;
        var cp = parseInt(hex, 16);
        return cp > 0 && cp <= 0x10FFFF ? String.fromCodePoint(cp) : '�';
      });
  }

  function styleHasRemote(v) {
    return /(?:url\(\s*['"]?|['"])\s*https:/i.test(cssUnescape(v).replace(/[\t\n\r]/g, ''));
  }

  function remoteImageRefCount(tagName, getAttribute) {
    var count = 0;
    var tag = String(tagName || '').toLowerCase();
    var attrs = IMAGE_URL_ATTRS_BY_TAG[tag] || [];
    for (var i = 0; i < attrs.length; i++) {
      var v = getAttribute(attrs[i]);
      if (v == null) continue;
      if (attrs[i] === 'srcset' ? srcsetHasRemote(v) : isRemoteURL(v)) count++;
    }
    // Legacy background attribute (<body>/<table>/<td>) and inline styles.
    var bg = getAttribute('background');
    if (bg != null && isRemoteURL(bg)) count++;
    var style = getAttribute('style');
    if (style != null && styleHasRemote(style)) count++;
    return count;
  }

  function install(marked, options) {
    options = options || {};
    if (!marked || typeof marked.use !== 'function') return false;
    marked.use({
      extensions: [frontMatterExtension(), wikilinkExtension(options)],
      hooks: { postprocess: labelCodeBlocks }
    });
    return true;
  }

  return {
    install: install,
    remoteImageRefCount: remoteImageRefCount,
    // Exposed for tests.
    _parseFrontMatter: parseFrontMatter,
    _parseWikiLink: parseWikiLink,
    _labelCodeBlocks: labelCodeBlocks
  };
})();
