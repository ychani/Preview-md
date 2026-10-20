import XCTest
@testable import MdReaderCore

/// The app and the Quick Look extension both depend on the vendored resource
/// bundle resolving; a missing file degrades to a blank or failed preview.
final class ResourcesTests: XCTestCase {

    func testBundleResolves() {
        XCTAssertNotNil(MdReaderResources.bundle, "PreviewMD_MdReaderCore.bundle not found")
    }

    func testPreviewHTMLURLResolves() throws {
        let url = try XCTUnwrap(MdReaderResources.previewHTMLURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testVendoredResourcesResolve() throws {
        let resources: [(String, String)] = [
            ("preview", "html"),
            ("preview", "css"),
            ("marked.min", "js"),
            ("purify.min", "js"),
            ("markdown-extensions", "js"),
            ("mermaid.min", "js"),
            ("THIRD_PARTY_NOTICES", "md"),
        ]
        for (name, ext) in resources {
            let url = try XCTUnwrap(MdReaderResources.url(forResource: name, withExtension: ext),
                                    "\(name).\(ext) missing from the resource bundle")
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
            XCTAssertGreaterThan(size ?? 0, 0, "\(name).\(ext) is empty")
        }
    }

    /// preview.js captures PreviewMDExtensions at load, so the extensions
    /// script must come first.
    func testPreviewHTMLLoadsExtensionsBeforePreviewJS() throws {
        let url = try XCTUnwrap(MdReaderResources.previewHTMLURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        let ext = try XCTUnwrap(html.range(of: "<script src=\"markdown-extensions.js\"></script>"))
        let shell = try XCTUnwrap(html.range(of: "<script src=\"preview.js\"></script>"))
        XCTAssertLessThan(ext.lowerBound, shell.lowerBound)
    }

    func testMissingResourceReturnsNil() {
        XCTAssertNil(MdReaderResources.url(forResource: "does-not-exist", withExtension: "js"))
    }
}
