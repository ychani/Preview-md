import Foundation
import MdReaderCore
import WebKit

/// Serves images that sit next to the previewed document over the
/// `previewmd-local:` scheme, so relative `![](img/x.png)` works without
/// giving the web view `file:` access.
///
/// URLs look like `previewmd-local://<token>/<relative/path>`. Each document
/// folder gets its own token (`register(folder:)`), so the host part pins
/// a request to the folder it was rendered for: switching documents can't
/// serve a cached or in-flight image from the wrong folder, and only folders
/// of documents the user opened are reachable at all. Path validation
/// (traversal, symlinks, image-only types) lives in
/// `MarkdownRenderBridge.resolveLocalImage`.
///
/// Must be registered on the `WKWebViewConfiguration` before the web view is
/// created. All entry points are called on the main thread.
final class LocalImageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = MarkdownRenderBridge.localImageScheme

    private var folderByToken: [String: URL] = [:]
    private var tokenByFolder: [URL: String] = [:]
    private var activeTasks = Set<ObjectIdentifier>()
    private let ioQueue = DispatchQueue(label: "previewmd.local-images", qos: .userInitiated)

    /// Returns the URL prefix (`previewmd-local://<token>/`) for images
    /// relative to `folder`.
    func register(folder: URL) -> String {
        let key = folder.standardizedFileURL
        if let token = tokenByFolder[key] {
            return "\(Self.scheme)://\(token)/"
        }
        let token = "doc-\(folderByToken.count + 1)"
        folderByToken[token] = key
        tokenByFolder[key] = token
        return "\(Self.scheme)://\(token)/"
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              let token = url.host?.lowercased(),
              let folder = folderByToken[token] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        activeTasks.insert(id)
        ioQueue.async { [weak self] in
            var payload: (Data, String)?
            if let hit = MarkdownRenderBridge.resolveLocalImage(url, documentFolder: folder),
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
}
