import Foundation

/// Shared resource access for the MdReader app and its Quick Look extension.
public enum MdReaderResources {
    /// The bundle holding preview.html / preview.css / marked.min.js / purify.min.js.
    public static let bundle: Bundle = .module

    public static func url(forResource name: String, withExtension ext: String) -> URL? {
        bundle.url(forResource: name, withExtension: ext)
    }

    /// URL to the preview.html shell. Nil if the bundle is misconfigured.
    public static var previewHTMLURL: URL? {
        url(forResource: "preview", withExtension: "html")
    }
}
