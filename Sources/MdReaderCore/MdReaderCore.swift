import Foundation

private final class BundleLocator {}

/// Shared resource access for the MdReader app and its Quick Look extension.
public enum MdReaderResources {
    private static let bundleName = "PreviewMD_MdReaderCore.bundle"

    /// The bundle holding preview.html / preview.css / marked.min.js / purify.min.js.
    ///
    /// Deliberately avoids SPM's generated `Bundle.module`: its accessor calls
    /// `fatalError` when the bundle isn't at an expected path, which crashes
    /// the Quick Look extension process instead of degrading. This lookup
    /// covers the app bundle, the .appex, and bare `swift run` layouts, and
    /// returns nil-equivalent behavior (empty resources) rather than trapping.
    public static let bundle: Bundle? = {
        var candidates: [URL?] = [
            Bundle.main.resourceURL,                                  // .app / .appex Contents/Resources
            Bundle(for: BundleLocator.self).resourceURL,              // host of the static library
            Bundle.main.bundleURL,                                    // swift run: .build/<config>/
            Bundle.main.executableURL?.deletingLastPathComponent(),   // next to the binary
            Bundle(for: BundleLocator.self).bundleURL
                .deletingLastPathComponent(),                         // swift test: sibling of the .xctest bundle
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(bundleName),
               FileManager.default.fileExists(atPath: url.path),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }()

    public static func url(forResource name: String, withExtension ext: String) -> URL? {
        bundle?.url(forResource: name, withExtension: ext)
    }

    /// URL to the preview.html shell. Nil if the bundle is misconfigured.
    public static var previewHTMLURL: URL? {
        url(forResource: "preview", withExtension: "html")
    }
}
