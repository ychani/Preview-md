import Foundation

/// Helpers for sending markdown text into the preview WebView safely.
public enum MarkdownRenderBridge {
    /// Builds a JavaScript expression that calls `render(<escapedMarkdown>)` in the
    /// preview WebView. Uses JSONSerialization to guarantee the string is a valid JS
    /// literal regardless of backticks, quotes, backslashes, or embedded newlines.
    public static func renderJS(for markdown: String) -> String? {
        renderJS(for: markdown, scroll: .keep)
    }

    /// Like `renderJS(for:)`, also telling `render()` what to do with the
    /// scroll position: `.keep` sends no options (`render(md)`), `.top` sends
    /// `{"resetScroll":true}`, `.restore(y)` sends `{"scrollY":y}`.
    public static func renderJS(for markdown: String, scroll: RenderScroll) -> String? {
        guard let arr = jsonArrayLiteral(markdown) else { return nil }
        // `arr` is ["..."]; evaluating (arr)[0] yields the safely-encoded string.
        switch scroll {
        case .keep:
            return "render((\(arr))[0])"
        case .top:
            return "render((\(arr))[0],{\"resetScroll\":true})"
        case .restore(let y):
            guard y.isFinite, y >= 0 else { return "render((\(arr))[0])" }
            return "render((\(arr))[0],{\"scrollY\":\(y)})"
        }
    }

    /// Like `renderJS(for:)`, but first tells the page where relative images
    /// resolve (`previewmd-local://<token>/`), or that they don't (nil).
    public static func renderJS(for markdown: String, imageBase: String?) -> String? {
        guard let render = renderJS(for: markdown) else { return nil }
        let base: String
        if let imageBase {
            guard let arr = jsonArrayLiteral(imageBase) else { return nil }
            base = "(\(arr))[0]"
        } else {
            base = "null"
        }
        return "setImageBase(\(base));\(render)"
    }

    /// Like `renderJS(for:imageBase:)`, plus wikilink data, sent before the
    /// render call:
    ///
    /// - `setImageRootBase(<string|null>)` — the base that root-relative
    ///   paths (wikilink `path`s) resolve against for images, e.g.
    ///   `previewmd-local://<root-token>/`; nil sends `null`.
    /// - `setWikiLinks(<object|null>)` — `{ "<key>": { "path": "<POSIX path
    ///   relative to the workspace root containing the target>", "kind":
    ///   "note" | "image" } }`. Keys are the link target as written inside
    ///   `[[ ]]` (trimmed, before `#` and `|`); see `WikiLink.lookupKeys` /
    ///   `WikiLinkIndex.resolutions(in:from:)`. Unresolved targets are absent;
    ///   `wikiLinks == nil` sends `null` (wikilinks not supported here).
    ///
    /// Both calls are guarded (`typeof f === "function"`) so a page without
    /// them still renders. Output shape:
    /// `setImageBase(…);<guarded setImageRootBase(…)>;<guarded setWikiLinks(…)>;render(…)`.
    public static func renderJS(
        for markdown: String,
        imageBase: String?,
        imageRootBase: String? = nil,
        wikiLinks: [String: WikiLinkResolution]?,
        scroll: RenderScroll = .keep
    ) -> String? {
        guard let render = renderJS(for: markdown, scroll: scroll),
              let base = stringOrNullLiteral(imageBase),
              let rootBase = stringOrNullLiteral(imageRootBase),
              let links = wikiLinksJSON(wikiLinks) else { return nil }
        return "setImageBase(\(base));"
            + guardedCall("setImageRootBase", rootBase) + ";"
            + guardedCall("setWikiLinks", links) + ";"
            + render
    }

    /// A JS expression for `value` (`(["…"])[0]`), or `null` for nil.
    private static func stringOrNullLiteral(_ value: String?) -> String? {
        guard let value else { return "null" }
        return jsonArrayLiteral(value).map { "(\($0))[0]" }
    }

    /// The `setWikiLinks` argument: a JSON object literal, or `null`.
    static func wikiLinksJSON(_ wikiLinks: [String: WikiLinkResolution]?) -> String? {
        guard let wikiLinks else { return "null" }
        var object: [String: [String: String]] = [:]
        for (key, resolution) in wikiLinks {
            object[key] = ["path": resolution.relativePath, "kind": resolution.kind.rawValue]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private static func guardedCall(_ function: String, _ argument: String) -> String {
        "(typeof \(function)===\"function\"&&\(function)(\(argument)))"
    }

    static func jsonArrayLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(
                withJSONObject: [value], options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Content Security Policy

    /// The preview shell's CSP. Remote (https) images are blocked unless the
    /// user opts in for the current document. `previewmd-local:` serves images
    /// from the document's folder (see `resolveLocalImage`). CSP `img-src`
    /// also governs `srcset`, CSS `url()` in style attributes, and the legacy
    /// `background` attribute, so this one directive covers every image load.
    /// `style-src 'unsafe-inline'` stays because Mermaid injects `<style>`.
    ///
    /// No `'self'` anywhere: the shell is a `file:` document, and WebKit
    /// lets `'self'` in a file: document match *any* URL (verified: with
    /// `img-src 'self'` an https image loads; with `script-src 'self'` an
    /// https script runs). The `file:` scheme-source is the tight equivalent
    /// for the bundled scripts and stylesheet.
    public static func contentSecurityPolicy(allowRemoteImages: Bool) -> String {
        let img = allowRemoteImages
            ? "img-src data: \(localImageScheme): https:"
            : "img-src data: \(localImageScheme):"
        return "default-src 'none'; script-src file:; style-src file: 'unsafe-inline'; "
            + "\(img); base-uri 'none'; form-action 'none'"
    }

    /// Returns the preview shell HTML with its CSP switched to the requested
    /// mode. The template (preview.html) must carry the default, strict policy
    /// verbatim; if it does not, this returns nil so callers fail closed
    /// instead of loading a shell with an unknown policy.
    public static func previewShellHTML(template: String, allowRemoteImages: Bool) -> String? {
        let strict = contentSecurityPolicy(allowRemoteImages: false)
        guard template.components(separatedBy: strict).count == 2 else { return nil }
        if !allowRemoteImages { return template }
        return template.replacingOccurrences(
            of: strict, with: contentSecurityPolicy(allowRemoteImages: true))
    }

    // MARK: - Links

    /// Resolves a relative link from the previewed document (`other.md`,
    /// `../docs/guide.markdown#setup`, `sub%20dir/x.md`) to an existing
    /// Markdown file, or nil. Links with a scheme, network-path links
    /// (`//host`), non-Markdown targets and missing files are refused.
    public static func resolveMarkdownLink(_ href: String, documentURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#") else { return nil }
        let components = URLComponents(string: trimmed)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                .flatMap { URLComponents(string: $0) }
        guard let components, components.scheme == nil, components.host == nil else { return nil }
        let encodedPath = components.percentEncodedPath
        guard !encodedPath.isEmpty else { return nil }
        let folder = documentURL.deletingLastPathComponent()
        guard let target = URL(string: encodedPath, relativeTo: folder)?
                .absoluteURL.standardizedFileURL,
              target.isFileURL,
              markdownExtensions.contains(target.pathExtension.lowercased()) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
              !isDir.boolValue else { return nil }
        return target
    }

    static let markdownExtensions: Set<String> = ["md", "markdown"]

    // MARK: - Local images

    /// URL scheme the preview uses for images next to the document.
    /// `previewmd-local://<folder-token>/<relative/path.png>`.
    public static let localImageScheme = "previewmd-local"

    /// Image types the local scheme will serve, by lowercase extension.
    public static let localImageMIMETypes: [String: String] = [
        "png": "image/png",
        "apng": "image/apng",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "svg": "image/svg+xml",
        "bmp": "image/bmp",
        "ico": "image/x-icon",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "heic": "image/heic",
        "heif": "image/heif",
    ]

    /// Largest local image the scheme will serve.
    public static let maxLocalImageBytes = 64 * 1024 * 1024

    /// Maps a `previewmd-local:` request to a file on disk, or nil if it must
    /// be refused. A request is served only if:
    /// - its path has no `.`/`..` segments (after percent-decoding),
    /// - it passes `resolveImageFile` (inside `documentFolder` with symlinks
    ///   resolved, image extension, regular file),
    /// - it is at most `maxLocalImageBytes`.
    public static func resolveLocalImage(
        _ url: URL, documentFolder: URL
    ) -> (fileURL: URL, mimeType: String)? {
        guard url.scheme?.lowercased() == localImageScheme else { return nil }
        let path = url.path  // percent-decoded
        guard !path.contains("\0") else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty,
              !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        guard let file = resolveImageFile(segments: segments, inside: documentFolder),
              let mime = localImageMIMETypes[file.ext] else { return nil }
        if file.size > maxLocalImageBytes { return nil }
        return (URL(fileURLWithPath: file.path), mime)
    }

    /// The path policy shared by the app's `previewmd-local:` scheme and
    /// Quick Look's `LocalImageInliner`. `segments` are already
    /// percent-decoded, non-empty path components relative to `folder`;
    /// callers decide which `.`/`..` segments they accept (both currently
    /// refuse them). Returns the file only if:
    /// - with symlinks resolved, it is inside `folder` (also resolved), so a
    ///   symlink can't escape the folder,
    /// - both the requested name and the resolved file have an image
    ///   extension (`localImageMIMETypes`),
    /// - it is an existing regular file.
    /// `ext` is the resolved file's lowercase extension; `size` is in bytes.
    static func resolveImageFile(
        segments: [String], inside folder: URL
    ) -> (path: String, ext: String, size: Int)? {
        guard !segments.isEmpty,
              !segments.contains(where: { $0.isEmpty || $0.contains("\0") }) else { return nil }
        guard let requestedExt = segments.last.map({ ($0 as NSString).pathExtension.lowercased() }),
              localImageMIMETypes[requestedExt] != nil else { return nil }

        guard let root = canonicalPath(folder.path) else { return nil }
        let candidate = segments.reduce(URL(fileURLWithPath: root, isDirectory: true)) {
            $0.appendingPathComponent($1)
        }
        guard let resolved = canonicalPath(candidate.path) else { return nil }
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard resolved.hasPrefix(rootPrefix) else { return nil }

        let resolvedExt = (resolved as NSString).pathExtension.lowercased()
        guard localImageMIMETypes[resolvedExt] != nil else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return (resolved, resolvedExt, size)
    }

    /// realpath(3): absolute, symlink-free path, or nil if it doesn't exist.
    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
