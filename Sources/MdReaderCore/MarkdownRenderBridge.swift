import Foundation

/// Helpers for sending markdown text into the preview WebView safely.
public enum MarkdownRenderBridge {
    /// Builds a JavaScript expression that calls `render(<escapedMarkdown>)` in the
    /// preview WebView. Uses JSONSerialization to guarantee the string is a valid JS
    /// literal regardless of backticks, quotes, backslashes, or embedded newlines.
    public static func renderJS(for markdown: String) -> String? {
        guard let arr = jsonArrayLiteral(markdown) else { return nil }
        // `arr` is ["..."]; evaluating (arr)[0] yields the safely-encoded string.
        return "render((\(arr))[0])"
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
    public static func contentSecurityPolicy(allowRemoteImages: Bool) -> String {
        let img = allowRemoteImages
            ? "img-src 'self' data: \(localImageScheme): https:"
            : "img-src 'self' data: \(localImageScheme):"
        return "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
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
    /// - the file, with symlinks resolved, is inside `documentFolder` (also
    ///   resolved) — so neither `..` nor a symlink can escape the folder,
    /// - both the requested name and the resolved file have an image extension,
    /// - it is an existing regular file.
    public static func resolveLocalImage(
        _ url: URL, documentFolder: URL
    ) -> (fileURL: URL, mimeType: String)? {
        guard url.scheme?.lowercased() == localImageScheme else { return nil }
        let path = url.path  // percent-decoded
        guard !path.contains("\0") else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty,
              !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        guard let requestedExt = segments.last.map({ ($0 as NSString).pathExtension.lowercased() }),
              localImageMIMETypes[requestedExt] != nil else { return nil }

        guard let root = canonicalPath(documentFolder.path) else { return nil }
        let candidate = segments.reduce(URL(fileURLWithPath: root, isDirectory: true)) {
            $0.appendingPathComponent($1)
        }
        guard let resolved = canonicalPath(candidate.path) else { return nil }
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard resolved.hasPrefix(rootPrefix) else { return nil }

        let resolvedExt = (resolved as NSString).pathExtension.lowercased()
        guard let mime = localImageMIMETypes[resolvedExt] else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        if let size = attrs[.size] as? NSNumber, size.intValue > maxLocalImageBytes { return nil }
        return (URL(fileURLWithPath: resolved), mime)
    }

    /// realpath(3): absolute, symlink-free path, or nil if it doesn't exist.
    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
