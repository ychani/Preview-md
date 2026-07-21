import XCTest
@testable import MdReaderCore

final class MarkdownDocumentIOTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MdReaderCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFixture(_ data: Data, name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testUTF8() throws {
        let text = "# Hello 한국어 🚀"
        let url = try writeFixture(Data(text.utf8), name: "utf8.md")
        let doc = try MarkdownDocumentIO.read(from: url)
        XCTAssertEqual(doc.text, text)
        XCTAssertEqual(doc.encoding, .utf8)
    }

    func testEmptyFile() throws {
        let url = try writeFixture(Data(), name: "empty.md")
        let doc = try MarkdownDocumentIO.read(from: url)
        XCTAssertEqual(doc.text, "")
        XCTAssertEqual(doc.encoding, .utf8)
    }

    func testUTF16WithBOM() throws {
        let text = "# Bonjour à tous"
        let data = try XCTUnwrap(text.data(using: .utf16)) // includes BOM
        let url = try writeFixture(data, name: "utf16.md")
        let doc = try MarkdownDocumentIO.read(from: url)
        XCTAssertEqual(doc.text, text)
        XCTAssertNotEqual(doc.encoding, .utf8)
    }

    func testLatin1() throws {
        let text = "Caf\u{00E9} r\u{00E9}sum\u{00E9}"
        let data = try XCTUnwrap(text.data(using: .isoLatin1))
        let url = try writeFixture(data, name: "latin1.md")
        let doc = try MarkdownDocumentIO.read(from: url)
        XCTAssertEqual(doc.text, text)
        XCTAssertNotEqual(doc.encoding, .utf8)
    }

    func testRoundTripPreservesEncoding() throws {
        // What was read as Latin-1 must be writable back as Latin-1.
        let text = "Caf\u{00E9}"
        let data = try XCTUnwrap(text.data(using: .isoLatin1))
        let url = try writeFixture(data, name: "roundtrip.md")
        let doc = try MarkdownDocumentIO.read(from: url)
        XCTAssertNotNil(doc.text.data(using: doc.encoding))
    }

    func testMissingFileThrowsUnreadable() {
        let url = tempDir.appendingPathComponent("does-not-exist.md")
        XCTAssertThrowsError(try MarkdownDocumentIO.read(from: url)) { error in
            guard case MarkdownDocumentIO.ReadError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }
}
