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

    // MARK: - Format detection and write round-trips

    private func bytes(at url: URL) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: url))
    }

    /// Reads `original`, saves the document unchanged, and asserts the bytes
    /// on disk are identical; then appends a line and checks the new bytes
    /// match `expectedAfterEdit`.
    private func assertRoundTrip(
        _ original: Data, name: String,
        expectedFormat: MarkdownDocumentIO.Format,
        edit: String, expectedAfterEdit: Data,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = try writeFixture(original, name: name)
        let doc = try MarkdownDocumentIO.read(from: url)
        XCTAssertEqual(doc.format, expectedFormat, file: file, line: line)
        XCTAssertFalse(doc.text.contains("\r"), "text should be LF-normalized", file: file, line: line)

        try MarkdownDocumentIO.write(doc.text, to: url, format: doc.format)
        XCTAssertEqual(try bytes(at: url), [UInt8](original), "unchanged save must be byte-identical",
                       file: file, line: line)

        try MarkdownDocumentIO.write(doc.text + edit, to: url, format: doc.format)
        XCTAssertEqual(try bytes(at: url), [UInt8](expectedAfterEdit), file: file, line: line)
        XCTAssertEqual(try MarkdownDocumentIO.read(from: url).format, expectedFormat, file: file, line: line)
    }

    func testRoundTripUTF8() throws {
        try assertRoundTrip(
            Data("# Hi 한국어\nline\n".utf8), name: "u8.md",
            expectedFormat: .init(encoding: .utf8),
            edit: "더\n", expectedAfterEdit: Data("# Hi 한국어\nline\n더\n".utf8))
    }

    func testRoundTripUTF8BOMIsPreserved() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        try assertRoundTrip(
            Data(bom + Array("# Hi\n".utf8)), name: "u8bom.md",
            expectedFormat: .init(encoding: .utf8, hasByteOrderMark: true),
            edit: "é\n", expectedAfterEdit: Data(bom + Array("# Hi\né\n".utf8)))
    }

    func testUTF8BOMIsNotPartOfText() throws {
        let url = try writeFixture(Data([0xEF, 0xBB, 0xBF] + Array("# A".utf8)), name: "bomtext.md")
        XCTAssertEqual(try MarkdownDocumentIO.read(from: url).text, "# A")
    }

    func testRoundTripUTF16LittleEndian() throws {
        let le = { (s: String) in Data([0xFF, 0xFE]) + s.data(using: .utf16LittleEndian)! }
        try assertRoundTrip(
            le("# Ünïcode\n"), name: "u16le.md",
            expectedFormat: .init(encoding: .utf16LittleEndian, hasByteOrderMark: true),
            edit: "🚀\n", expectedAfterEdit: le("# Ünïcode\n🚀\n"))
    }

    func testRoundTripUTF16BigEndianStaysBigEndian() throws {
        let be = { (s: String) in Data([0xFE, 0xFF]) + s.data(using: .utf16BigEndian)! }
        try assertRoundTrip(
            be("# Ünïcode\n"), name: "u16be.md",
            expectedFormat: .init(encoding: .utf16BigEndian, hasByteOrderMark: true),
            edit: "x\n", expectedAfterEdit: be("# Ünïcode\nx\n"))
    }

    func testRoundTripLatin1() throws {
        let latin1 = { (s: String) in s.data(using: .isoLatin1)! }
        let url = try writeFixture(latin1("Caf\u{00E9}\n"), name: "l1.md")
        let doc = try MarkdownDocumentIO.read(from: url)
        XCTAssertNotEqual(doc.encoding, .utf8)
        try MarkdownDocumentIO.write(doc.text + "na\u{00EF}ve\n", to: url, format: doc.format)
        XCTAssertEqual(try bytes(at: url), [UInt8](latin1("Caf\u{00E9}\nna\u{00EF}ve\n")))
    }

    func testRoundTripShiftJIS() throws {
        let sjis = { (s: String) in s.data(using: .shiftJIS)! }
        let url = try writeFixture(sjis("# 日本語のテキスト\nこんにちは\n"), name: "sjis.md")
        let doc = try MarkdownDocumentIO.read(from: url)
        XCTAssertEqual(doc.text, "# 日本語のテキスト\nこんにちは\n")
        try MarkdownDocumentIO.write(doc.text + "さようなら\n", to: url, format: doc.format)
        XCTAssertEqual(try bytes(at: url), [UInt8](sjis("# 日本語のテキスト\nこんにちは\nさようなら\n")))
    }

    func testRoundTripCRLFStaysCRLF() throws {
        try assertRoundTrip(
            Data("# A\r\nb\r\n".utf8), name: "crlf.md",
            expectedFormat: .init(encoding: .utf8, lineEnding: .crlf),
            edit: "c\nd\n", expectedAfterEdit: Data("# A\r\nb\r\nc\r\nd\r\n".utf8))
    }

    func testCRLFInUTF16() throws {
        let le = { (s: String) in Data([0xFF, 0xFE]) + s.data(using: .utf16LittleEndian)! }
        try assertRoundTrip(
            le("a\r\nb\r\n"), name: "u16crlf.md",
            expectedFormat: .init(encoding: .utf16LittleEndian, hasByteOrderMark: true, lineEnding: .crlf),
            edit: "c\n", expectedAfterEdit: le("a\r\nb\r\nc\r\n"))
    }

    func testDominantLineEnding() {
        XCTAssertNil(MarkdownDocumentIO.dominantLineEnding(in: "no breaks"))
        XCTAssertEqual(MarkdownDocumentIO.dominantLineEnding(in: "a\nb\n"), .lf)
        XCTAssertEqual(MarkdownDocumentIO.dominantLineEnding(in: "a\r\nb\r\nc\n"), .crlf)
        XCTAssertEqual(MarkdownDocumentIO.dominantLineEnding(in: "a\rb\r"), .cr)
        XCTAssertEqual(MarkdownDocumentIO.dominantLineEnding(in: "a\r\nb\n"), .lf) // tie → LF
    }

    func testNULBytesAreRejectedAsBinary() throws {
        let url = try writeFixture(Data([0x23, 0x20, 0x41, 0x00, 0x42, 0x0A]), name: "binary.md")
        XCTAssertThrowsError(try MarkdownDocumentIO.read(from: url)) { error in
            guard case MarkdownDocumentIO.ReadError.undecodable = error else {
                return XCTFail("expected .undecodable, got \(error)")
            }
        }
    }

    func testPNGIsRejectedAsBinary() throws {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]
        let url = try writeFixture(Data(png), name: "image.md")
        XCTAssertThrowsError(try MarkdownDocumentIO.read(from: url))
    }

    func testUnencodableTextThrows() throws {
        let url = try writeFixture(Data("Caf\u{00E9}".data(using: .isoLatin1)!), name: "l1emoji.md")
        let doc = try MarkdownDocumentIO.read(from: url)
        XCTAssertThrowsError(try MarkdownDocumentIO.write(doc.text + "🚀", to: url, format: doc.format)) { error in
            guard case MarkdownDocumentIO.WriteError.unencodable = error else {
                return XCTFail("expected .unencodable, got \(error)")
            }
        }
        // The original file is untouched.
        XCTAssertEqual(try MarkdownDocumentIO.read(from: url).text, "Caf\u{00E9}")
    }

    func testWritePreservesPermissionsAndExtendedAttributes() throws {
        let url = try writeFixture(Data("# A\n".utf8), name: "perms.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let set = url.path.withCString { setxattr($0, "com.previewmd.test", "tag", 3, 0, 0) }
        XCTAssertEqual(set, 0)

        try MarkdownDocumentIO.write("# B\n", to: url, format: .utf8)

        XCTAssertEqual(try MarkdownDocumentIO.read(from: url).text, "# B\n")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o640)
        var buffer = [UInt8](repeating: 0, count: 8)
        let length = url.path.withCString { getxattr($0, "com.previewmd.test", &buffer, buffer.count, 0, 0) }
        XCTAssertEqual(length, 3)
        XCTAssertEqual(Array(buffer.prefix(3)), Array("tag".utf8))
    }

    func testWriteFollowsSymlinks() throws {
        let real = try writeFixture(Data("old\n".utf8), name: "real.md")
        let link = tempDir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try MarkdownDocumentIO.write("new\n", to: link, format: .utf8)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "new\n")
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
    }

    // MARK: - Re-reads keep the known format

    func testASCIIOnlyLatin1FileKeepsLatin1AfterOwnSave() throws {
        let latin1 = MarkdownDocumentIO.Format(encoding: .isoLatin1)
        let url = try writeFixture(Data(), name: "ascii-latin1.md")
        // Our own save of ASCII-only text: the bytes are valid UTF-8 too.
        try MarkdownDocumentIO.write("plain ascii\n", to: url, format: latin1)
        XCTAssertEqual(try MarkdownDocumentIO.read(from: url).encoding, .utf8) // plain detection
        let reread = try MarkdownDocumentIO.read(from: url, preferring: latin1)
        XCTAssertEqual(reread.format, latin1)

        // A later non-ASCII save therefore stays Latin-1.
        try MarkdownDocumentIO.write(reread.text + "caf\u{00E9}\n", to: url, format: reread.format)
        XCTAssertEqual(try Data(contentsOf: url), "plain ascii\ncaf\u{00E9}\n".data(using: .isoLatin1))
    }

    func testPreferredFormatIsDroppedWhenFileWasReencodedExternally() throws {
        let url = try writeFixture(Data("caf\u{00E9}\n".utf8), name: "now-utf8.md")
        let doc = try MarkdownDocumentIO.read(from: url, preferring: .init(encoding: .isoLatin1))
        XCTAssertEqual(doc.encoding, .utf8)
        XCTAssertEqual(doc.text, "caf\u{00E9}\n")
    }

    func testPreferredLineEndingKeptWhenFileHasNoLineBreaks() throws {
        let url = try writeFixture(Data("one line".utf8), name: "oneline.md")
        let crlf = MarkdownDocumentIO.Format(encoding: .utf8, lineEnding: .crlf)
        XCTAssertEqual(try MarkdownDocumentIO.read(from: url, preferring: crlf).format, crlf)
    }

    // MARK: - Prefix reads (Quick Look)

    func testReadPrefixOfSmallFileIsComplete() throws {
        let url = try writeFixture(Data("# small\n".utf8), name: "small.md")
        let (doc, truncated) = try MarkdownDocumentIO.readPrefix(from: url, maxBytes: 1024)
        XCTAssertFalse(truncated)
        XCTAssertEqual(doc.text, "# small\n")
    }

    func testReadPrefixExactlyAtLimitIsNotTruncated() throws {
        let url = try writeFixture(Data("12345\n".utf8), name: "exact.md")
        XCTAssertFalse(try MarkdownDocumentIO.readPrefix(from: url, maxBytes: 6).isTruncated)
    }

    func testReadPrefixCutsAtLastLineBreak() throws {
        let line = "- item with ünïcödé text 🚀\n"
        let text = String(repeating: line, count: 2000)
        let url = try writeFixture(Data(text.utf8), name: "big.md")
        let limit = 10_000
        let (doc, truncated) = try MarkdownDocumentIO.readPrefix(from: url, maxBytes: limit)
        XCTAssertTrue(truncated)
        XCTAssertTrue(doc.text.hasSuffix("\n"))
        XCTAssertTrue(text.hasPrefix(doc.text))
        XCTAssertLessThanOrEqual(doc.text.utf8.count, limit)
        XCTAssertGreaterThan(doc.text.utf8.count, limit - line.utf8.count - 1)
    }

    func testReadPrefixOfSingleHugeLineEndsOnCharacterBoundary() throws {
        let text = String(repeating: "한", count: 1000) // 3 bytes each
        let url = try writeFixture(Data(text.utf8), name: "oneline-big.md")
        let (doc, truncated) = try MarkdownDocumentIO.readPrefix(from: url, maxBytes: 1000)
        XCTAssertTrue(truncated)
        XCTAssertTrue(text.hasPrefix(doc.text))
        XCTAssertEqual(doc.text.count, 333)
    }

    func testReadPrefixOfUTF16() throws {
        let text = String(repeating: "línea 🚀\n", count: 500)
        let data = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        let url = try writeFixture(data, name: "u16-big.md")
        let (doc, truncated) = try MarkdownDocumentIO.readPrefix(from: url, maxBytes: 1001)
        XCTAssertTrue(truncated)
        XCTAssertEqual(doc.encoding, .utf16BigEndian)
        XCTAssertTrue(text.hasPrefix(doc.text))
        XCTAssertTrue(doc.text.hasSuffix("\n"))
    }

    func testIsMarkdownFile() {
        for name in ["a.md", "b.MD", "c.markdown", "d.mdown", "e.mkd", "f.mkdn", "dir/g.Markdown"] {
            XCTAssertTrue(MarkdownDocumentIO.isMarkdownFile(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.txt", "b.mdx", "README", "c.md.bak", ".md"] {
            XCTAssertFalse(MarkdownDocumentIO.isMarkdownFile(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    func testWriteCreatesMissingFile() throws {
        let url = tempDir.appendingPathComponent("new.md")
        try MarkdownDocumentIO.write("hello\n", to: url, format: .utf8)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello\n")
    }
}
