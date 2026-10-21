import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MdReaderCore

final class LocalImageInlinerTests: XCTestCase {
    private var root: URL!
    /// The previewed document's folder, inside `root`.
    private var docs: URL!
    private var png: Data!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalImageInlinerTests-\(UUID().uuidString)", isDirectory: true)
        docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        png = try Self.pngData()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private static func pngData(width: Int = 3, height: Int = 2) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0, green: 0.5, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private static let svg = Data(#"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- comment -->
        <svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4"/></svg>
        """#.utf8)

    @discardableResult
    private func write(_ data: Data, _ relativePath: String, in base: URL? = nil) throws -> URL {
        let url = (base ?? docs).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// File names the inliner read, in order.
    private final class Reads {
        var names: [String] = []
    }

    private func inline(_ html: String, limits: LocalImageInliner.Limits = .quickLook,
                        reads: Reads? = nil) -> LocalImageInliner.Result {
        LocalImageInliner.inline(html: html, documentFolder: docs, limits: limits) { url in
            reads?.names.append(url.lastPathComponent)
            return try Data(contentsOf: url)
        }
    }

    // MARK: - Inlining

    func testSiblingPNGBecomesAttachment() throws {
        try write(png, "a.png")
        let result = inline(#"<p><img src="a.png" alt="A"></p>"#)
        XCTAssertEqual(result.html, #"<p><img src="cid:img-1" alt="A"></p>"#)
        let image = try XCTUnwrap(result.attachments["img-1"])
        XCTAssertEqual(image.data, png)
        XCTAssertEqual(image.contentType, .png)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.refused, 0)
    }

    func testMarkdownAndRawHTMLImagesThroughRenderer() throws {
        try write(png, "img/a.png")
        try write(Self.svg, "sub/b.svg")
        let doc = try MarkdownHTMLRenderer.renderDocument(
            markdown: "![a](./img/a.png)\n\n<img src=\"sub/b.svg\" alt=\"b\" width=\"10\">\n",
            title: "README.md", imageFolder: docs)
        XCTAssertEqual(doc.attachments.count, 2)
        XCTAssertTrue(doc.html.contains(#"<img src="cid:img-1" alt="a">"#), doc.html)
        XCTAssertTrue(doc.html.contains(#"<img src="cid:img-2" alt="b" width="10">"#), doc.html)
        XCTAssertEqual(doc.attachments["img-2"]?.contentType, .svg)
    }

    func testEntityAndPercentEncodedNames() throws {
        try write(png, "my pic & co.png")
        try write(png, "사진/그림.png")
        let result = inline("""
            <img src="my%20pic%20&amp;%20co.png" alt="1">\
            <img src="%EC%82%AC%EC%A7%84/%EA%B7%B8%EB%A6%BC.png" alt="2">\
            <img src="my pic &#38; co.png?raw=1#frag" alt="3">
            """)
        XCTAssertEqual(result.attachments.count, 2, result.html)
        XCTAssertTrue(result.html.contains(#"<img src="cid:img-1" alt="1">"#), result.html)
        XCTAssertTrue(result.html.contains(#"<img src="cid:img-2" alt="2">"#), result.html)
        XCTAssertTrue(result.html.contains(#"<img src="cid:img-1" alt="3">"#), result.html)
    }

    func testDuplicatesShareOneAttachmentAndOneRead() throws {
        try write(png, "a.png")
        let reads = Reads()
        let result = inline(#"<img src="a.png"><img src="./a.png"><IMG SRC='a.png'>"#, reads: reads)
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(reads.names, ["a.png"])
        XCTAssertEqual(result.html.components(separatedBy: "cid:img-1").count - 1, 3, result.html)
    }

    func testSrcsetStrippedOnRewrittenImage() throws {
        try write(png, "a.png")
        let result = inline(#"<img srcset="a.png 2x, https://x/b.png 3x" src="a.png" alt="A">"#)
        XCTAssertEqual(result.html, #"<img src="cid:img-1" alt="A">"#)
    }

    func testUnrelatedTagsAndEscapedCodeUntouched() throws {
        try write(png, "a.png")
        let html = #"<a href="a.png">a</a><pre><code>&lt;img src="a.png"&gt;</code></pre><imgx src="a.png">"#
        let result = inline(html)
        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    // MARK: - Refusals

    func testNonLocalSourcesLeftAlone() throws {
        for src in ["https://example.com/a.png", "http://x/a.png", "file:///etc/a.png",
                    "data:image/png;base64,AAAA", "cid:img-9", "#top", "", "JaVaScRiPt:x",
                    " https://example.com/a.png"] {
            XCTAssertEqual(LocalImageInliner.classify(src), .notLocal, src)
            let html = "<img src=\"\(src)\" alt=\"x\">"
            let result = inline(html)
            XCTAssertEqual(result.html, html, src)
            XCTAssertEqual(result.refused, 0, src)
        }
    }

    func testTraversalAndAbsolutePathsRefused() throws {
        try write(png, "outside.png", in: root)
        try write(png, "a.png")
        for src in ["../outside.png", "img/../a.png", "..%2Foutside.png", "%2E%2E/outside.png",
                    "&#46;&#46;/outside.png", "/etc/a.png", "//host/a.png", "\(root.path)/outside.png",
                    "a\\..\\..\\outside.png"] {
            XCTAssertEqual(LocalImageInliner.classify(src), .refused, src)
            let html = "<img src=\"\(src)\" alt=\"x\">"
            let result = inline(html)
            XCTAssertEqual(result.html, html, src)
            XCTAssertTrue(result.attachments.isEmpty, src)
            XCTAssertEqual(result.refused, 1, src)
        }
        XCTAssertEqual(LocalImageInliner.classify("./img/a.png"), .local(["img", "a.png"]))
    }

    func testSymlinkEscapeRefusedButInternalSymlinkAllowed() throws {
        let outside = try write(png, "outside.png", in: root)
        let inside = try write(png, "real/in.png")
        try FileManager.default.createSymbolicLink(
            at: docs.appendingPathComponent("escape.png"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: docs.appendingPathComponent("link.png"), withDestinationURL: inside)
        try FileManager.default.createSymbolicLink(
            at: docs.appendingPathComponent("up"), withDestinationURL: root)
        let result = inline(#"<img src="escape.png"><img src="up/outside.png"><img src="link.png">"#)
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(result.refused, 2)
        XCTAssertTrue(result.html.hasPrefix(#"<img src="escape.png"><img src="up/outside.png">"#), result.html)
        XCTAssertTrue(result.html.hasSuffix(#"<img src="cid:img-1">"#), result.html)
    }

    func testNonImageContentRefused() throws {
        try write(Data("not an image\n".utf8), "fake.png")
        try write(Data("<html><body>hi</body></html>".utf8), "page.svg")
        try write(Data("secret".utf8), "notes.txt")
        try FileManager.default.createDirectory(
            at: docs.appendingPathComponent("dir.png"), withIntermediateDirectories: true)
        let result = inline(#"<img src="fake.png"><img src="page.svg"><img src="notes.txt"><img src="dir.png"><img src="missing.png">"#)
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertEqual(result.refused, 5)
    }

    func testSVGRootCheck() {
        XCTAssertTrue(LocalImageInliner.hasSVGRoot(Self.svg))
        XCTAssertTrue(LocalImageInliner.hasSVGRoot(Data(#"<svg:svg xmlns:svg="http://www.w3.org/2000/svg"/>"#.utf8)))
        XCTAssertFalse(LocalImageInliner.hasSVGRoot(Data("<html><svg/></html>".utf8)))
        XCTAssertFalse(LocalImageInliner.hasSVGRoot(Data("not xml".utf8)))
        XCTAssertFalse(LocalImageInliner.hasSVGRoot(Data()))
        // External entities are never fetched; the root is still read.
        XCTAssertTrue(LocalImageInliner.hasSVGRoot(Data("""
            <?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]>
            <svg xmlns="http://www.w3.org/2000/svg"><text>&x;</text></svg>
            """.utf8)))
        XCTAssertEqual(LocalImageInliner.verifiedType(of: png, ext: "png"), .png)
        XCTAssertEqual(LocalImageInliner.verifiedType(of: png, ext: "jpg"), .png, "real type wins")
        XCTAssertNil(LocalImageInliner.verifiedType(of: Data("hello".utf8), ext: "png"))
    }

    // MARK: - Budgets

    func testPerImageCapSkipsWithoutReading() throws {
        try write(png, "big.png")
        let reads = Reads()
        let limits = LocalImageInliner.Limits(maxImageBytes: png.count - 1, maxTotalBytes: 1 << 20, maxImages: 64)
        let result = inline(#"<img src="big.png" alt="Big" title="t" srcset="big.png 2x">"#,
                            limits: limits, reads: reads)
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(reads.names, [], "size is checked before reading")
        XCTAssertEqual(result.html, #"<img title="Image too large to preview" alt="Big">"#)
    }

    func testTotalAndCountCaps() throws {
        try write(png, "a.png")
        try write(png, "b.png")
        try write(png, "c.png")
        let html = #"<img src="a.png"><img src="b.png"><img src="c.png"><img src="b.png">"#

        let total = inline(html, limits: .init(maxImageBytes: png.count, maxTotalBytes: png.count * 2, maxImages: 64))
        XCTAssertEqual(total.attachments.count, 2)
        XCTAssertEqual(total.skipped, 1)
        XCTAssertTrue(total.html.hasSuffix(#"<img title="Image too large to preview"><img src="cid:img-2">"#),
                      total.html)

        let count = inline(html, limits: .init(maxImageBytes: 1 << 20, maxTotalBytes: 1 << 20, maxImages: 1))
        XCTAssertEqual(count.attachments.count, 1)
        XCTAssertEqual(count.skipped, 3, "b.png twice + c.png")
    }

    func testQuickLookLimits() {
        XCTAssertEqual(LocalImageInliner.Limits.quickLook,
                       .init(maxImageBytes: 4 << 20, maxTotalBytes: 16 << 20, maxImages: 64))
    }

    // MARK: - Obsidian embeds

    private func embed(_ src: String) -> String {
        "<img src=\"\(src)\" alt=\"e\" data-previewmd-embed=\"\">"
    }

    func testEmbedLookupOrder() throws {
        try write(png, "attachments/a.png")
        try write(Self.svg, "assets/b.svg")
        try write(png, "images/c.png")
        try write(png, "d.png")
        let result = inline(embed("a.png") + embed("b.svg") + embed("c.png") + embed("d.png"))
        XCTAssertEqual(result.attachments.count, 4, result.html)
        XCTAssertEqual(result.html, [1, 2, 3, 4].map { "<img src=\"cid:img-\($0)\" alt=\"e\">" }.joined())
        XCTAssertEqual(result.attachments["img-2"]?.contentType, .svg)
    }

    func testEmbedPrefersDocumentFolder() throws {
        let other = try Self.pngData(width: 5, height: 5)
        try write(png, "x.png")
        try write(other, "attachments/x.png")
        try write(other, "images/x.png")
        let reads = Reads()
        let result = inline(embed("x.png"), reads: reads)
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(result.attachments["img-1"]?.data, png)
        XCTAssertEqual(reads.names, ["x.png"], "stops at the first hit")
    }

    func testEmbedSubpathAndMissing() throws {
        try write(png, "attachments/pics/p.png")
        let result = inline(embed("pics/p.png") + embed("nope.png") + embed("../x.png"))
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(result.refused, 2)
        XCTAssertEqual(result.html,
            #"<img src="cid:img-1" alt="e">"#
            + #"<img title="Image not found" alt="e">"#
            + #"<img title="Image not found" alt="e">"#)
    }

    func testPlainImageDoesNotSearchAttachmentFolders() throws {
        try write(png, "attachments/a.png")
        let result = inline(#"<img src="a.png">"#)
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertEqual(result.html, #"<img src="a.png">"#)
    }

    func testRendererResolvesObsidianEmbed() throws {
        try write(png, "attachments/pic one.png")
        let doc = try MarkdownHTMLRenderer.renderDocument(
            markdown: "![[pic one.png|120]]\n\n![[missing.png]]\n\n![[note]]",
            title: "n.md", imageFolder: docs)
        XCTAssertEqual(doc.attachments.count, 1)
        XCTAssertTrue(doc.html.contains(#"<img src="cid:img-1" alt="pic one.png" width="120">"#), doc.html)
        XCTAssertTrue(doc.html.contains(#"<img title="Image not found" alt="missing.png">"#), doc.html)
        XCTAssertTrue(doc.html.contains(#"<span class="wikilink">note</span>"#), doc.html)
        XCTAssertFalse(doc.html.contains("data-previewmd-embed"), doc.html)
    }
}
