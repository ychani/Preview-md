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
    /// Quick Look's HTML preview does not execute JavaScript, so the primary
    /// injection risk is inert; scripts and event handlers are stripped anyway
    /// and a CSP meta tag blocks remote loads (tracking pixels in previews of
    /// untrusted files).
    public static func renderDocument(markdown: String, title: String = "") throws -> String {
        let body = try renderBody(markdown: markdown)
        let css = loadCSS()
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: file:; style-src 'unsafe-inline';">
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
        ctx.setObject(markdown, forKeyedSubscript: "__mdSource" as NSString)
        let result = ctx.evaluateScript("marked.parse(__mdSource)")
        guard jsError == nil, let html = result?.toString(), !result!.isUndefined else {
            // Parser failure on this input — degrade to escaped plain text.
            return "<pre>\(escapeHTML(markdown))</pre>"
        }
        return sanitize(html)
    }

    /// Defense-in-depth stripping for a renderer that never executes JS:
    /// drop script/style/iframe/object/embed/form blocks and inline handlers.
    static func sanitize(_ html: String) -> String {
        var out = html
        let blockTags = ["script", "style", "iframe", "object", "embed", "form"]
        for tag in blockTags {
            out = out.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>",
                with: "", options: [.regularExpression, .caseInsensitive])
            out = out.replacingOccurrences(
                of: "<\(tag)\\b[^>]*/?>",
                with: "", options: [.regularExpression, .caseInsensitive])
        }
        // Inline event handlers (onclick=..., onerror=...) and javascript: URLs.
        out = out.replacingOccurrences(
            of: "\\son\\w+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            with: "", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(
            of: "(href|src)\\s*=\\s*([\"']?)\\s*javascript:[^\"'>\\s]*\\2",
            with: "", options: [.regularExpression, .caseInsensitive])
        return out
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
