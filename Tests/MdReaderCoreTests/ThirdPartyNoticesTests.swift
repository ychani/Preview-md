import CryptoKit
import XCTest
@testable import MdReaderCore

/// The About panel's Credits come from the notices file in the resource
/// bundle; it must stay in lockstep with the repo-root copy and cover every
/// vendored script.
final class ThirdPartyNoticesTests: XCTestCase {

    private var rootNoticesURL: URL {
        // Tests/MdReaderCoreTests/ThirdPartyNoticesTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("THIRD_PARTY_NOTICES.md")
    }

    private func bundledNotices() throws -> String {
        let url = try XCTUnwrap(
            MdReaderResources.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
            "THIRD_PARTY_NOTICES.md missing from the MdReaderCore resource bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testBundledCopyMatchesRoot() throws {
        let root = try String(contentsOf: rootNoticesURL, encoding: .utf8)
        let bundled = try bundledNotices()
        XCTAssertEqual(bundled, root, "Resources/THIRD_PARTY_NOTICES.md differs from the repo-root copy")
    }

    func testMentionsEveryVendoredLibrary() throws {
        let text = try bundledNotices()
        for needle in ["marked.min.js", "purify.min.js", "mermaid.min.js",
                       "marked", "DOMPurify", "mermaid",
                       "Apache License", "MIT License", "ISC",
                       "d3", "dagre-d3-es", "cytoscape", "katex", "dayjs",
                       "lodash-es", "khroma", "langium", "chevrotain"] {
            XCTAssertTrue(text.contains(needle), "notices should mention \(needle)")
        }
    }

    func testRecordsVendoredFileHashes() throws {
        let text = try bundledNotices()
        for name in ["marked.min", "purify.min", "mermaid.min"] {
            let url = try XCTUnwrap(MdReaderResources.url(forResource: name, withExtension: "js"))
            let data = try Data(contentsOf: url)
            let digest = sha256Hex(data)
            XCTAssertTrue(text.contains(digest), "\(name).js sha256 \(digest) not recorded in notices")
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
