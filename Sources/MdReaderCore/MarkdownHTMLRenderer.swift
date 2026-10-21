import Foundation
import JavaScriptCore

/// Renders markdown to a complete standalone HTML document without a WebView,
/// by running the vendored marked.js inside JavaScriptCore. Used by the Quick
/// Look extension's data-based preview (`QLPreviewReply`), where Quick Look
/// renders the returned HTML itself and never executes scripts.
public enum MarkdownHTMLRenderer {

    public enum RenderError: LocalizedError {
        case engineUnavailable

        public var errorDescription: String? {
            switch self {
            case .engineUnavailable:
                return "Markdown render engine could not be initialized."
            }
        }
    }

    /// A rendered Quick Look document plus the local images it references
    /// as `cid:` URLs (see `LocalImageInliner`).
    public struct RenderedDocument {
        public let html: String
        /// Content-ID (without `cid:`) -> image bytes and type.
        public let attachments: [String: InlinedImage]
        /// Local images left out because a size/count budget was exhausted.
        public let skipped: Int
        /// Local-looking image references refused by the path or content
        /// policy, or missing.
        public let refused: Int
    }

    /// Renders a full HTML document for the given markdown.
    ///
    /// Security: the Content-Security-Policy meta tag allows no scripts,
    /// plugins, frames, forms, `<base>` rewrites or remote loads, only inline
    /// styles and `cid:`/`data:` images, and Quick Look doesn't execute
    /// JavaScript. Quick Look was observed loading remote images despite the
    /// CSP, so `blockExternalImages(_:)` also removes every image URL that
    /// isn't `cid:`/`data:` (no tracking pixels in previews of untrusted
    /// files). `sanitize(_:)` is defense-in-depth on top of both.
    public static func renderDocument(markdown: String, title: String = "") throws -> String {
        try renderDocument(markdown: markdown, title: title, imageFolder: nil).html
    }

    /// Like `renderDocument(markdown:title:)`; with an `imageFolder` (the
    /// previewed file's folder) it also inlines relative local images from
    /// that folder and its subfolders as `cid:` attachments. Remote images
    /// stay blocked by the CSP.
    public static func renderDocument(
        markdown: String, title: String = "", imageFolder: URL?,
        limits: LocalImageInliner.Limits = .quickLook
    ) throws -> RenderedDocument {
        var body = try renderBody(markdown: markdown)
        var attachments: [String: InlinedImage] = [:]
        var skipped = 0
        var refused = 0
        if let imageFolder {
            let inlined = LocalImageInliner.inline(html: body, documentFolder: imageFolder, limits: limits)
            body = inlined.html
            attachments = inlined.attachments
            skipped = inlined.skipped
            refused = inlined.refused
        }
        body = blockExternalImages(body)
        let css = loadCSS()
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <title>\(escapeHTML(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
        return RenderedDocument(html: html, attachments: attachments, skipped: skipped, refused: refused)
    }

    /// Renders markdown to an HTML fragment via marked.js in JavaScriptCore.
    /// A fresh context per call keeps this thread-safe (JSContext is not).
    public static func renderBody(markdown: String) throws -> String {
        guard let ctx = JSContext(),
              let markedURL = MdReaderResources.url(forResource: "marked.min", withExtension: "js"),
              let source = try? String(contentsOf: markedURL, encoding: .utf8)
        else {
            throw RenderError.engineUnavailable
        }
        var jsError: String?
        ctx.exceptionHandler = { _, exception in
            jsError = exception?.toString()
        }
        ctx.evaluateScript(source)
        guard jsError == nil,
              let marked = ctx.objectForKeyedSubscript("marked"), !marked.isUndefined
        else {
            throw RenderError.engineUnavailable
        }
        ctx.evaluateScript("marked.setOptions({ gfm: true, breaks: false });")
        installExtensions(in: ctx)
        jsError = nil
        ctx.setObject(markdown, forKeyedSubscript: "__mdSource" as NSString)
        let result = ctx.evaluateScript("marked.parse(__mdSource)")
        guard jsError == nil, let html = result?.toString(), !result!.isUndefined else {
            // Parser failure on this input — degrade to escaped plain text.
            return "<pre>\(escapeHTML(markdown))</pre>"
        }
        return sanitize(html)
    }

    /// Front matter tables, `[[wikilinks]]` (as plain spans — Quick Look
    /// has no navigation) and `![[image.png]]` embeds (as `<img>` tags marked
    /// `data-previewmd-embed`, resolved by `LocalImageInliner`) via the same markdown-extensions.js the app uses.
    /// Best effort: if the script is missing or throws, plain marked output
    /// is still a correct preview.
    private static func installExtensions(in ctx: JSContext) {
        guard let url = MdReaderResources.url(forResource: "markdown-extensions", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        ctx.evaluateScript(source)
        ctx.evaluateScript("""
            if (typeof PreviewMDExtensions === 'object' && PreviewMDExtensions) {
              PreviewMDExtensions.install(marked, { mode: 'static' });
            }
            """)
    }

    /// CSP for the Quick Look document. `default-src 'none'` already covers
    /// scripts, objects and frames; they're repeated so the policy reads as the
    /// control it is. `base-uri` and `form-action` don't fall back to
    /// `default-src`, so they must be listed. Nothing remote (`https:`) is allowed.
    /// Images come only from `cid:` attachments (`LocalImageInliner`, which
    /// enforces the local path policy) or inline `data:` URIs — no `file:`.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "img-src cid: data:",
        "style-src 'unsafe-inline'",
    ].joined(separator: "; ") + ";"

    /// Defense-in-depth only, NOT a full HTML sanitizer: the CSP in
    /// `renderDocument` is the security control (and Quick Look runs no JS).
    /// This removes the obvious active content so a CSP regression doesn't
    /// immediately become exploitable:
    /// - script/style/iframe/object/embed/form elements (with content) and
    ///   meta/base/link tags, repeated until stable so fragments like
    ///   `<scr<script>ipt>` can't reassemble;
    /// - inside each start tag, `on*` handler attributes (also after `/`, as in
    ///   `<img/onerror=…>`) and any attribute whose entity-decoded value is a
    ///   `javascript:`/`vbscript:` URL (`&#106;avascript:`, `java&#9;script:`).
    /// Attribute stripping is scoped to tags, so prose and code such as
    /// `let onChange = f` are left alone.
    static func sanitize(_ html: String) -> String {
        let pairedTags = ["script", "style", "iframe", "object", "embed", "form"]
        let strayTags = pairedTags + ["meta", "base", "link"]
        let paired = pairedTags.joined(separator: "|")
        let stray = strayTags.joined(separator: "|")

        var out = html
        while true {
            var next = out.replacingOccurrences(
                of: #"<(\#(paired))\b[^>]*>[\s\S]*?</\1\b[^>]*>"#,
                with: "", options: [.regularExpression, .caseInsensitive])
            next = next.replacingOccurrences(
                of: #"</?(\#(stray))\b[^>]*>"#,
                with: "", options: [.regularExpression, .caseInsensitive])
            if next == out { break }
            out = next
        }

        return replaceMatches(in: out, pattern: startTag) { tag in
            replaceMatches(in: tag, pattern: attribute) { attr in
                isDangerousAttribute(attr) ? "" : attr
            }
        }
    }

    /// Removes every image/media URL that isn't `cid:` or `data:` from the
    /// Quick Look document, so nothing is fetched from the network or disk
    /// even though Quick Look's renderer was observed (macOS 26) loading
    /// remote `https:` images despite the meta CSP. Per start tag:
    /// - `src`, `poster`, `background` (any tag), and `href`/`xlink:href` on
    ///   SVG `<image>`, `<feImage>`, `<use>`: dropped unless `cid:`/`data:`;
    /// - `srcset`: always dropped (LocalImageInliner never produces one);
    /// - `style`: dropped if it could load anything (`url(`, `image-set(`,
    ///   `@import`, or any CSS escape).
    /// An `<img>` that loses its `src` still shows its `alt` text.
    static func blockExternalImages(_ html: String) -> String {
        replaceMatches(in: html, pattern: startTag) { tag in
            let tagName = tag.range(of: #"^<[a-z][a-z0-9:-]*"#, options: [.regularExpression, .caseInsensitive])
                .map { tag[$0].dropFirst().lowercased() } ?? ""
            let hrefIsResource = ["image", "feimage", "use", "svg:image", "svg:use"].contains(tagName)
            // With the whitespace before each attribute, so dropping one
            // leaves no gap.
            return replaceMatches(in: tag, pattern: #"\s*"# + attribute) { attr in
                guard let (name, value) = attributeParts(attr) else { return attr }
                switch name {
                case "srcset":
                    return ""
                case "style":
                    return styleCanLoad(value) ? "" : attr
                case "src", "poster", "background":
                    return isInlineImageURL(value) ? attr : ""
                case "href", "xlink:href":
                    return !hrefIsResource || isInlineImageURL(value) ? attr : ""
                default:
                    return attr
                }
            }
        }
    }

    private static func isInlineImageURL(_ value: String) -> Bool {
        let url = String(String.UnicodeScalarView(
            LocalImageInliner.decodeHTMLEntities(value).unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }
        )).lowercased()
        return url.hasPrefix("cid:") || url.hasPrefix("data:")
    }

    private static func styleCanLoad(_ value: String) -> Bool {
        let css = LocalImageInliner.decodeHTMLEntities(value).lowercased()
            .filter { !$0.isWhitespace }
        return css.contains("\\") || css.contains("url(") || css.contains("image-set(")
            || css.contains("@import") || css.contains("image(")
    }

    /// A start tag. Quoted values may contain `>`. Spans never cross a bare
    /// `<`, so an unbalanced quote can't swallow the rest of the document
    /// (the second alternative catches that case).
    static let startTag = #"<[a-z](?:"[^"]*"|'[^']*'|[^"'<>])*>|<[a-z][^<>]*>"#
    /// One `name = value` attribute inside a start tag, after a space, `/`,
    /// or the previous value's closing quote.
    static let attribute = #"(?<=[\s/"'])[^\s/>="']+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#

    /// Splits one match of `attribute` into its lowercased name and its value
    /// with the surrounding quotes removed (entities still encoded).
    static func attributeParts(_ attr: String) -> (name: String, value: String)? {
        guard let eq = attr.firstIndex(of: "=") else { return nil }
        let name = attr[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var value = attr[attr.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote = value.first, quote == "\"" || quote == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return (name, value)
    }

    /// `attr` is one match of the attribute pattern: name, `=`, value.
    private static func isDangerousAttribute(_ attr: String) -> Bool {
        guard let (name, value) = attributeParts(attr) else { return false }
        if name.hasPrefix("on") { return true }
        // Browsers ignore whitespace and control characters in a URL scheme.
        let scheme = String(String.UnicodeScalarView(
            decodeEntities(value).unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }
        )).lowercased()
        return scheme.hasPrefix("javascript:") || scheme.hasPrefix("vbscript:")
    }

    /// Decodes numeric character references plus the named ones that matter
    /// for URL schemes (`&colon;`, `&Tab;`, `&NewLine;`). Not a general decoder.
    static func decodeEntities(_ text: String) -> String {
        var out = replaceMatches(in: text, pattern: #"&#(x[0-9a-f]+|[0-9]+);?"#) { ref in
            let digits = ref.dropFirst(2).filter { $0 != ";" }
            let code = digits.lowercased().hasPrefix("x")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
        for (entity, char) in [("&colon;", ":"), ("&tab;", "\t"), ("&newline;", "\n")] {
            out = out.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
        }
        return out
    }

    /// Replaces each (case-insensitive) match of `pattern` with `transform(match)`.
    static func replaceMatches(in text: String, pattern: String,
                                       _ transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += transform(ns.substring(with: match.range))
            last = NSMaxRange(match.range)
        }
        return out + ns.substring(from: last)
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func loadCSS() -> String {
        guard let url = MdReaderResources.url(forResource: "preview", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
    }
}
