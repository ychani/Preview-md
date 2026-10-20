import AppKit
import MdReaderCore
import os.log
import Quartz

private let qlLog = Logger(subsystem: "com.narnarlabs.previewmd.quicklook", category: "preview")

/// Quick Look preview provider. QLIsDataBasedPreview is set in QLInfo.plist,
/// so Quick Look calls `providePreview(for:)` and renders the returned HTML
/// itself — there is no WebView in this process.
@objc(PreviewViewController)
public final class PreviewViewController: NSViewController, QLPreviewingController {

    /// Quick Look reads at most this much of a file; the rest is elided with
    /// a banner so huge files preview quickly and within the memory budget.
    static let maxPreviewBytes = 2 * 1024 * 1024

    static let truncationBanner = """
        > **Preview truncated** — showing the first 2 MB of this file. \
        Open it in PreviewMD to see the whole file.


        """

    /// Data-based previews never show this view, but NSViewController must
    /// not look for a nib named after the class.
    public override func loadView() {
        view = NSView()
    }

    // MARK: - QLPreviewingController

    public func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        qlLog.info("providePreview: \(url.lastPathComponent, privacy: .public)")

        let html: String
        do {
            let (document, isTruncated) = try MarkdownDocumentIO.readPrefix(
                from: url, maxBytes: Self.maxPreviewBytes)
            let markdown = isTruncated ? Self.truncationBanner + document.text : document.text
            html = try MarkdownHTMLRenderer.renderDocument(
                markdown: markdown, title: url.lastPathComponent)
        } catch {
            // Show the reason instead of a blank/failed preview.
            qlLog.error("preview failed: \(error.localizedDescription, privacy: .public)")
            html = Self.errorPage(fileName: url.lastPathComponent, message: error.localizedDescription)
        }

        let data = Data(html.utf8)
        qlLog.info("providePreview: rendered \(data.count) bytes of HTML")
        return QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 800, height: 900)
        ) { reply in
            reply.title = url.lastPathComponent
            reply.stringEncoding = .utf8
            return data
        }
    }

    // MARK: - Error page

    static func errorPage(fileName: String, message: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(escapeHTML(fileName))</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 13px -apple-system, system-ui, sans-serif; margin: 0; height: 100vh;
                 display: flex; align-items: center; justify-content: center; }
          main { max-width: 440px; padding: 24px; text-align: center; }
          h1 { font-size: 15px; font-weight: 600; margin: 0 0 8px; }
          p { margin: 0; opacity: 0.7; line-height: 1.45; }
        </style>
        </head>
        <body><main>
        <h1>Can’t preview “\(escapeHTML(fileName))”</h1>
        <p>\(escapeHTML(message))</p>
        </main></body>
        </html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
