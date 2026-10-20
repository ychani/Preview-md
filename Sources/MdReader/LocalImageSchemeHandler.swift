import Foundation
import MdReaderCore
import WebKit

/// Serves the previewed document's local images over the `previewmd-local:`
/// scheme, so relative `![](img/x.png)` and wikilink embeds (`![[x.png]]`)
/// work without giving the web view `file:` access.
///
/// URLs look like `previewmd-local://<token>/<root-relative/path>`. A token
/// stands for one *grant*: the root a document may load images from — the
/// workspace root containing it, or its own folder when it is not in a
/// workspace — plus the document's folder. The host part pins a request to
/// the grant it was rendered for: switching documents can't serve a cached
/// or in-flight image from the wrong root, and only roots of documents the
/// user opened are reachable at all. Path validation (traversal, symlinks,
/// image-only types) lives in `MarkdownRenderBridge.resolveLocalImage`.
///
/// Must be registered on the `WKWebViewConfiguration` before the web view is
/// created. All entry points are called on the main thread.
final class LocalImageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = MarkdownRenderBridge.localImageScheme

    /// What one token may serve.
    private struct Grant: Hashable {
        /// Requests resolve against this folder and must stay inside it
        /// (symlinks resolved).
        let root: URL
        /// The document's folder and its components below `root` (empty when
        /// they are the same). Images under the document's folder that only
        /// reach outside `root` through a symlink are still served, as they
        /// were before roots existed.
        let documentFolder: URL
        let documentComponents: [String]
    }

    /// The `setImageBase` / `setImageRootBase` values for one document.
    struct Bases: Equatable {
        /// `previewmd-local://<token>/<document folder below the root>/`:
        /// what relative image srcs resolve against.
        let imageBase: String
        /// `previewmd-local://<token>/`: what root-relative wikilink embed
        /// paths resolve against.
        let rootBase: String
    }

    private var grantByToken: [String: Grant] = [:]
    private var tokenByGrant: [Grant: String] = [:]
    private var activeTasks = Set<ObjectIdentifier>()
    private let ioQueue = DispatchQueue(label: "previewmd.local-images", qos: .userInitiated)

    /// Registers the image grant for the document at `documentURL` inside
    /// workspace root `root` (nil, or a root not containing the document:
    /// the document's own folder) and returns its bases.
    func register(documentURL: URL, root: URL?) -> Bases {
        let folder = FileNode.canonicalURL(documentURL.deletingLastPathComponent())
        var grantRoot = folder
        var components: [String] = []
        if let root, let relative = FileNode.relativeComponents(of: folder, under: root) {
            grantRoot = FileNode.canonicalURL(root)
            components = relative
        }
        let grant = Grant(root: grantRoot, documentFolder: folder, documentComponents: components)
        let token: String
        if let existing = tokenByGrant[grant] {
            token = existing
        } else {
            token = "doc-\(grantByToken.count + 1)"
            grantByToken[token] = grant
            tokenByGrant[grant] = token
        }
        let rootBase = "\(Self.scheme)://\(token)/"
        let folderPath = components.map(Self.encodeComponent).map { $0 + "/" }.joined()
        return Bases(imageBase: rootBase + folderPath, rootBase: rootBase)
    }

    private static let componentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/;")
        return set
    }()

    private static func encodeComponent(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? name
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              let token = url.host?.lowercased(),
              let grant = grantByToken[token] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        activeTasks.insert(id)
        ioQueue.async { [weak self] in
            var payload: (Data, String)?
            if let hit = Self.resolve(url, grant: grant),
               let data = try? Data(contentsOf: hit.fileURL, options: .mappedIfSafe) {
                payload = (data, hit.mimeType)
            }
            DispatchQueue.main.async {
                // WebKit raises if a stopped task is messaged.
                guard let self, self.activeTasks.remove(id) != nil else { return }
                guard let (data, mime) = payload else {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mime,
                        "Content-Length": String(data.count),
                        "Cache-Control": "no-store",
                        "X-Content-Type-Options": "nosniff",
                    ])
                urlSchemeTask.didReceive(response ?? URLResponse(
                    url: url, mimeType: mime,
                    expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    /// The file `url` names inside `grant.root`; failing that, a request
    /// under the document's folder is retried against that folder itself.
    private static func resolve(_ url: URL, grant: Grant) -> (fileURL: URL, mimeType: String)? {
        if let hit = MarkdownRenderBridge.resolveLocalImage(url, documentFolder: grant.root) {
            return hit
        }
        let prefix = grant.documentComponents
        guard !prefix.isEmpty else { return nil }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count > prefix.count, Array(segments.prefix(prefix.count)) == prefix,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/" + segments.dropFirst(prefix.count).joined(separator: "/")
        guard let inFolder = components.url else { return nil }
        return MarkdownRenderBridge.resolveLocalImage(inFolder, documentFolder: grant.documentFolder)
    }
}
