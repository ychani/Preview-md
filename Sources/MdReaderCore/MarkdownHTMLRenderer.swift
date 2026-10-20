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

    /// Renders a full HTML document for the given markdown.
    ///
    /// The security control is the Content-Security-Policy meta tag: no
    /// scripts, plugins, frames, forms, `<base>` rewrites or remote loads
    /// (tracking pixels in previews of untrusted files), only inline styles
    /// and `data:`/`file:` images. Quick Look also doesn't execute JavaScript.
    /// `sanitize(_:)` is defense-in-depth on top of that, not the boundary.
    public static func renderDocument(markdown: String, title: String = "") throws -> String {
        let body = try renderBody(markdown: markdown)
        let css = loadCSS()
        return """
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

    /// Front matter tables and `[[wikilinks]]` (as plain spans — Quick Look
    /// has no navigation) via the same markdown-extensions.js the app uses.
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
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "img-src data: file:",
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

        // Start tags: quoted values may contain `>`. Spans never cross a bare
        // `<`, so an unbalanced quote can't swallow the rest of the document
        // (the second alternative catches that case).
        let startTag = #"<[a-z](?:"[^"]*"|'[^']*'|[^"'<>])*>|<[a-z][^<>]*>"#
        // name = value, after a space, `/`, or the previous value's closing quote
        let attribute = #"(?<=[\s/"'])[^\s/>="']+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#
        return replaceMatches(in: out, pattern: startTag) { tag in
            replaceMatches(in: tag, pattern: attribute) { attr in
                isDangerousAttribute(attr) ? "" : attr
            }
        }
    }

    /// `attr` is one match of the attribute pattern: name, `=`, value.
    private static func isDangerousAttribute(_ attr: String) -> Bool {
        guard let eq = attr.firstIndex(of: "=") else { return false }
        let name = attr[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("on") { return true }
        var value = attr[attr.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote = value.first, quote == "\"" || quote == "'" {
            value = String(value.dropFirst().dropLast())
        }
        // Browsers ignore whitespace and control characters in a URL scheme.
        let scheme = String(String.UnicodeScalarView(
            decodeEntities(value).unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }
        )).lowercased()
        return scheme.hasPrefix("javascript:") || scheme.hasPrefix("vbscript:")
    }

    /// Decodes numeric character references plus the named ones that matter
    /// for URL schemes (`&colon;`, `&Tab;`, `&NewLine;`). Not a general decoder.
    private static func decodeEntities(_ text: String) -> String {
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
    private static func replaceMatches(in text: String, pattern: String,
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
