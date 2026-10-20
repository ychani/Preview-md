import XCTest
@testable import MdReaderCore

final class FilePathDisplayTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func u(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testRelativePath() {
        let root = URL(fileURLWithPath: "/Users/someone/notes/", isDirectory: true)
        XCTAssertEqual(FilePathDisplay.relativePath(of: u("/Users/someone/notes/a/b.md"), in: root), "a/b.md")
        XCTAssertEqual(FilePathDisplay.relativePath(of: u("/Users/someone/notes/b.md"), in: root), "b.md")
        XCTAssertEqual(FilePathDisplay.relativePath(of: root, in: root), "")
        // Sibling with a shared name prefix is *not* inside the root.
        XCTAssertEqual(FilePathDisplay.relativePath(of: u("/Users/someone/notes2/x.md"), in: root),
                       FilePathDisplay.relativePath(of: u("/Users/someone/notes2/x.md"),
                                                    in: u("/nowhere")))
    }

    func testRelativePathAcrossPrivateVar() {
        XCTAssertEqual(FilePathDisplay.relativePath(of: u("/private/var/folders/x/doc.md"),
                                                    in: u("/var/folders")), "x/doc.md")
        XCTAssertEqual(FilePathDisplay.relativePath(of: u("/var/folders/x/doc.md"),
                                                    in: u("/private/var/folders")), "x/doc.md")
    }

    func testAbbreviatedParent() {
        XCTAssertEqual(FilePathDisplay.abbreviatedParent(of: u("/Users/someone/Documents/n/a.md"), home: home),
                       "~/Documents/n")
        XCTAssertEqual(FilePathDisplay.abbreviatedParent(of: u("/Users/someone/a.md"), home: home), "~")
        XCTAssertEqual(FilePathDisplay.abbreviatedParent(of: u("/Users/someoneelse/a.md"), home: home),
                       "/Users/someoneelse")
        XCTAssertEqual(FilePathDisplay.abbreviatedParent(of: u("/a.md"), home: home), "/")
    }

    func testDisambiguatedNamesUniqueAreNil() {
        let a = u("/Users/someone/n/a.md"), b = u("/Users/someone/n/b.md")
        let result = FilePathDisplay.disambiguatedNames([a, b], home: home)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[a], .some(nil))
        XCTAssertEqual(result[b], .some(nil))
    }

    func testDisambiguatedNamesShortestParent() {
        let x = u("/Users/someone/docs/a/README.md")
        let y = u("/Users/someone/docs/b/README.md")
        let z = u("/Users/someone/docs/b/other.md")
        let result = FilePathDisplay.disambiguatedNames([x, y, z], home: home)
        XCTAssertEqual(result[x], "a")
        XCTAssertEqual(result[y], "b")
        XCTAssertEqual(result[z], .some(nil))
    }

    func testDisambiguatedNamesNeedsMoreThanOneComponent() {
        let x = u("/Users/someone/src/x/README.md")
        let y = u("/Users/someone/lib/x/README.md")
        let result = FilePathDisplay.disambiguatedNames([x, y], home: home)
        XCTAssertEqual(result[x], "src/x")
        XCTAssertEqual(result[y], "lib/x")
    }

    func testDisambiguatedNamesWhenOneParentIsASuffixOfTheOther() {
        let short = u("/Users/someone/a/README.md")
        let long = u("/Users/someone/b/a/README.md")
        let result = FilePathDisplay.disambiguatedNames([short, long], home: home)
        XCTAssertEqual(result[long], "b/a")
        XCTAssertEqual(result[short], "someone/a")
    }

    func testDisambiguatedNamesFallsBackToAbbreviatedFullPath() {
        let top = u("/Users/someone/README.md")
        let nested = u("/x/Users/someone/README.md")
        let result = FilePathDisplay.disambiguatedNames([top, nested], home: home)
        XCTAssertEqual(result[top], "~")
        XCTAssertEqual(result[nested], "Users/someone")
    }

    func testDuplicateSpellingsOfOneFileAreNotRivals() {
        let a = u("/Users/someone/n/a.md")
        let b = URL(fileURLWithPath: "/Users/someone/n/../n/a.md")
        let result = FilePathDisplay.disambiguatedNames([a, b, a], home: home)
        XCTAssertEqual(result[a], .some(nil))
        XCTAssertEqual(result[b], .some(nil))
    }
}
