import XCTest
@testable import MdReaderCore

final class MarkdownRenderBridgeTests: XCTestCase {

    private func roundTrip(_ markdown: String) throws -> String {
        let js = try XCTUnwrap(MarkdownRenderBridge.renderJS(for: markdown))
        XCTAssertTrue(js.hasPrefix("render(("), "unexpected shape: \(js)")
        XCTAssertTrue(js.hasSuffix(")[0])"), "unexpected shape: \(js)")
        // Extract the JSON array literal and decode it back — what render()
        // receives must be byte-identical to the input.
        let jsonPart = String(js.dropFirst("render((".count).dropLast(")[0])".count))
        let decoded = try JSONSerialization.jsonObject(with: Data(jsonPart.utf8)) as? [String]
        return try XCTUnwrap(decoded?.first)
    }

    func testPlainText() throws {
        XCTAssertEqual(try roundTrip("# Hello"), "# Hello")
    }

    func testQuotesBackticksBackslashes() throws {
        let nasty = #"He said "hi" — `code` \ and \\ and 'single'"#
        XCTAssertEqual(try roundTrip(nasty), nasty)
    }

    func testNewlinesAndTabs() throws {
        let text = "line1\nline2\r\nline3\ttabbed"
        XCTAssertEqual(try roundTrip(text), text)
    }

    func testScriptInjectionAttempt() throws {
        let text = "</script><script>alert(1)</script>"
        XCTAssertEqual(try roundTrip(text), text)
    }

    func testUnicode() throws {
        let text = "한국어 · émoji 🚀 · 中文 · \u{2028}line-sep"
        XCTAssertEqual(try roundTrip(text), text)
    }

    func testEmptyString() throws {
        XCTAssertEqual(try roundTrip(""), "")
    }

    func testRenderWithImageBase() throws {
        let js = try XCTUnwrap(MarkdownRenderBridge.renderJS(
            for: "# Hi", imageBase: "previewmd-local://doc-1/"))
        XCTAssertEqual(js, ##"setImageBase((["previewmd-local:\/\/doc-1\/"])[0]);render((["# Hi"])[0])"##)
        let none = try XCTUnwrap(MarkdownRenderBridge.renderJS(for: "x", imageBase: nil))
        XCTAssertEqual(none, #"setImageBase(null);render((["x"])[0])"#)
        // A hostile base can't break out of the string literal.
        let evil = try XCTUnwrap(MarkdownRenderBridge.renderJS(for: "x", imageBase: "\");alert(1);//"))
        XCTAssertTrue(evil.hasPrefix(#"setImageBase((["\");alert(1);\/\/"])[0]);"#), evil)
    }
}

final class PreviewContentSecurityPolicyTests: XCTestCase {

    private func shippedShell() throws -> String {
        let url = try XCTUnwrap(MdReaderResources.previewHTMLURL, "preview.html missing from bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testStrictPolicyBlocksRemoteAndInlineScript() {
        let csp = MarkdownRenderBridge.contentSecurityPolicy(allowRemoteImages: false)
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("script-src file:;"))
        // WebKit lets 'self' in a file: document match any URL.
        XCTAssertFalse(csp.contains("'self'"))
        XCTAssertFalse(csp.contains("unsafe-eval"))
        XCTAssertFalse(csp.contains("https:"))
        XCTAssertTrue(csp.contains("img-src data: previewmd-local:;"))
        XCTAssertTrue(csp.contains("base-uri 'none'"))
        XCTAssertTrue(csp.contains("form-action 'none'"))
        // Only style-src may be unsafe-inline (Mermaid injects <style>).
        XCTAssertEqual(csp.components(separatedBy: "'unsafe-inline'").count, 2)
        XCTAssertTrue(csp.contains("style-src file: 'unsafe-inline'"))
    }

    func testOptInPolicyAddsHttpsToImagesOnly() {
        let csp = MarkdownRenderBridge.contentSecurityPolicy(allowRemoteImages: true)
        XCTAssertTrue(csp.contains("img-src data: previewmd-local: https:;"))
        XCTAssertFalse(csp.contains("'self'"))
        XCTAssertEqual(csp.components(separatedBy: "https:").count, 2, "https: must appear only in img-src")
        XCTAssertFalse(csp.contains("http:"))
    }

    func testShippedShellCarriesStrictPolicyAndNoInlineScript() throws {
        let html = try shippedShell()
        XCTAssertTrue(html.contains(MarkdownRenderBridge.contentSecurityPolicy(allowRemoteImages: false)))
        XCTAssertFalse(html.contains("<script>"), "inline scripts are blocked by CSP; use preview.js")
        XCTAssertTrue(html.contains(#"<script src="preview.js"></script>"#))
    }

    func testShellTemplating() throws {
        let html = try shippedShell()
        XCTAssertEqual(MarkdownRenderBridge.previewShellHTML(template: html, allowRemoteImages: false), html)
        let remote = try XCTUnwrap(MarkdownRenderBridge.previewShellHTML(template: html, allowRemoteImages: true))
        XCTAssertTrue(remote.contains(MarkdownRenderBridge.contentSecurityPolicy(allowRemoteImages: true)))
        XCTAssertFalse(remote.contains(MarkdownRenderBridge.contentSecurityPolicy(allowRemoteImages: false) + "\""))
    }

    func testShellTemplatingFailsClosedOnUnknownPolicy() {
        let html = #"<meta http-equiv="Content-Security-Policy" content="default-src *">"#
        XCTAssertNil(MarkdownRenderBridge.previewShellHTML(template: html, allowRemoteImages: true))
        XCTAssertNil(MarkdownRenderBridge.previewShellHTML(template: html, allowRemoteImages: false))
    }
}

final class MarkdownLinkResolutionTests: XCTestCase {
    private var root: URL!
    private var doc: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewmd-links-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("docs/sub dir"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs/folder.md"), withIntermediateDirectories: true)
        doc = root.appendingPathComponent("docs/readme.md")
        for path in ["docs/readme.md", "docs/other.md", "docs/sub dir/guide.markdown", "top.md", "docs/notes.txt"] {
            try Data("# x".utf8).write(to: root.appendingPathComponent(path))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func resolve(_ href: String) -> String? {
        MarkdownRenderBridge.resolveMarkdownLink(href, documentURL: doc)?
            .path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
    }

    func testResolvesRelativeMarkdownLinks() {
        XCTAssertEqual(resolve("other.md"), "docs/other.md")
        XCTAssertEqual(resolve("./other.md#section"), "docs/other.md")
        XCTAssertEqual(resolve("other.md?x=1"), "docs/other.md")
        XCTAssertEqual(resolve("sub%20dir/guide.markdown"), "docs/sub dir/guide.markdown")
        XCTAssertEqual(resolve("sub dir/guide.markdown"), "docs/sub dir/guide.markdown")
        XCTAssertEqual(resolve("../top.md"), "top.md")
    }

    func testRefusesEverythingElse() {
        XCTAssertNil(resolve("notes.txt"))
        XCTAssertNil(resolve("missing.md"))
        XCTAssertNil(resolve("folder.md"))
        XCTAssertNil(resolve("#heading"))
        XCTAssertNil(resolve(""))
        XCTAssertNil(resolve("https://example.com/x.md"))
        XCTAssertNil(resolve("file:///etc/x.md"))
        XCTAssertNil(resolve("//host/x.md"))
    }
}

final class LocalImageResolutionTests: XCTestCase {
    private var root: URL!
    private var docs: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewmd-img-\(UUID().uuidString)", isDirectory: true)
        docs = root.appendingPathComponent("docs", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: docs.appendingPathComponent("img sub"), withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(to: docs.appendingPathComponent("a.png"))
        try Data([0x89, 0x50]).write(to: docs.appendingPathComponent("img sub/b.JPG"))
        try Data("secret".utf8).write(to: docs.appendingPathComponent("secret.txt"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.png"))
        // Symlinks: one escaping the folder, one disguising a text file,
        // one harmlessly pointing at an image inside the folder.
        try fm.createSymbolicLink(at: docs.appendingPathComponent("escape.png"),
                                  withDestinationURL: root.appendingPathComponent("outside.png"))
        try fm.createSymbolicLink(at: docs.appendingPathComponent("fake.png"),
                                  withDestinationURL: docs.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: docs.appendingPathComponent("inside.png"),
                                  withDestinationURL: docs.appendingPathComponent("a.png"))
        try fm.createDirectory(at: docs.appendingPathComponent("dir.png"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func resolve(_ s: String) -> (fileURL: URL, mimeType: String)? {
        guard let url = URL(string: s) else { return nil }
        return MarkdownRenderBridge.resolveLocalImage(url, documentFolder: docs)
    }

    func testServesImagesInsideFolder() throws {
        let a = try XCTUnwrap(resolve("previewmd-local://d1/a.png"))
        XCTAssertEqual(a.mimeType, "image/png")
        XCTAssertEqual(a.fileURL.lastPathComponent, "a.png")
        let b = try XCTUnwrap(resolve("previewmd-local://d1/img%20sub/b.JPG"))
        XCTAssertEqual(b.mimeType, "image/jpeg")
        XCTAssertNotNil(resolve("previewmd-local://d1/inside.png"), "symlink within the folder is fine")
    }

    func testRejectsTraversal() {
        XCTAssertNil(resolve("previewmd-local://d1/../outside.png"))
        XCTAssertNil(resolve("previewmd-local://d1/..%2Foutside.png"))
        XCTAssertNil(resolve("previewmd-local://d1/img%20sub/..%2F..%2Foutside.png"))
        XCTAssertNil(resolve("previewmd-local://d1/./a.png"))
        XCTAssertNil(resolve("previewmd-local://d1/../../../../etc/passwd"))
    }

    func testRejectsSymlinkEscapesAndDisguises() {
        XCTAssertNil(resolve("previewmd-local://d1/escape.png"))
        XCTAssertNil(resolve("previewmd-local://d1/fake.png"))
    }

    func testRejectsNonImagesDirectoriesAndMissing() {
        XCTAssertNil(resolve("previewmd-local://d1/secret.txt"))
        XCTAssertNil(resolve("previewmd-local://d1/dir.png"))
        XCTAssertNil(resolve("previewmd-local://d1/missing.png"))
        XCTAssertNil(resolve("previewmd-local://d1/"))
        XCTAssertNil(resolve("file:///etc/hosts"))
        XCTAssertNil(resolve("https://example.com/a.png"))
    }
}
