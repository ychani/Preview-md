// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient

/// SPEC §16.5 and Appendix B: the Info.plist declaration and the wake URL.
final class DeclarationTests: XCTestCase {

    /// Appendix B, verbatim, as a parsed property list.
    private func appendixB() throws -> [String: Any] {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key>  <string>com.narnarlabs.previewmd</string>
        <key>UnivocalConnect</key>
        <dict>
            <key>Versions</key>        <array><integer>1</integer></array>
            <key>HotkeyTarget</key>    <true/>
            <key>WakeURLScheme</key>   <string>previewmd</string>
        </dict>
        <key>CFBundleURLTypes</key>
        <array><dict>
            <key>CFBundleURLName</key>    <string>com.narnarlabs.previewmd.url</string>
            <key>CFBundleURLSchemes</key> <array><string>previewmd</string></array>
            <key>LSHandlerRank</key>      <string>Owner</string>
        </dict></array>
        </dict></plist>
        """
        let any = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
        return try XCTUnwrap(any as? [String: Any])
    }

    func testAppendixBParsesAndIsValid() throws {
        let info = try appendixB()
        let d = try XCTUnwrap(UnivocalAppDeclaration(infoDictionary: info))
        XCTAssertEqual(d, UnivocalAppDeclaration(versions: [1], hotkeyTarget: true, wakeURLScheme: "previewmd"))
        XCTAssertEqual(d.problems(infoDictionary: info), [])
    }

    func testBundleOnDisk() throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let contents = dir.appendingPathComponent("Decl.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: try appendixB(), format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: dir.appendingPathComponent("Decl.app")))
        let d = try XCTUnwrap(UnivocalAppDeclaration.current(bundle: bundle))
        XCTAssertEqual(d.wakeURLScheme, "previewmd")
        XCTAssertEqual(d.problems(in: bundle), [])
        XCTAssertNil(UnivocalAppDeclaration.current(), "the test runner declares nothing")
    }

    func testProblemsAreListed() throws {
        var info = try appendixB()
        info["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["other"]]]
        let d = try XCTUnwrap(UnivocalAppDeclaration(infoDictionary: info))
        let p = d.problems(infoDictionary: info)
        XCTAssertEqual(p.count, 1)
        XCTAssertTrue(p[0].contains("not registered"), p[0])

        let bad = UnivocalAppDeclaration(versions: [], hotkeyTarget: false, wakeURLScheme: "Preview MD")
        let problems = bad.problems(infoDictionary: [:])
        XCTAssertEqual(problems.count, 4, "\(problems)")   // versions, hotkeyTarget, scheme syntax, registration
        XCTAssertTrue(UnivocalAppDeclaration(versions: [2], hotkeyTarget: true, wakeURLScheme: "previewmd")
            .problems(infoDictionary: try appendixB())[0].contains("no version this SDK speaks"))
        XCTAssertTrue(UnivocalAppDeclaration(versions: [1], hotkeyTarget: true, wakeURLScheme: nil)
            .problems(infoDictionary: [:]).contains { $0.contains("missing") })
    }

    func testIllTypedDeclarationsAreRejected() {
        XCTAssertNil(UnivocalAppDeclaration(infoDictionary: [:]))
        XCTAssertNil(UnivocalAppDeclaration(infoDictionary: ["UnivocalConnect": "yes"]))
        XCTAssertNil(UnivocalAppDeclaration(infoDictionary: ["UnivocalConnect": ["HotkeyTarget": true]]), "Versions is required")
        XCTAssertNil(UnivocalAppDeclaration(infoDictionary: ["UnivocalConnect": ["Versions": ["1"]]]))
        XCTAssertNil(UnivocalAppDeclaration(infoDictionary: ["UnivocalConnect": ["Versions": [1], "HotkeyTarget": 1]]),
                     "HotkeyTarget must be a boolean, not an integer")
        XCTAssertNil(UnivocalAppDeclaration(infoDictionary: ["UnivocalConnect": ["Versions": [1], "WakeURLScheme": 3]]))
        let minimal = UnivocalAppDeclaration(infoDictionary: ["UnivocalConnect": ["Versions": [1]]])
        XCTAssertEqual(minimal, UnivocalAppDeclaration(versions: [1], hotkeyTarget: false, wakeURLScheme: nil))
    }

    func testWakeURLMakeAndParse() throws {
        let url = try XCTUnwrap(UnivocalWakeURL.make(scheme: "previewmd", requestId: "h1"))
        XCTAssertEqual(url.absoluteString, "previewmd://univocal-connect/read?requestId=h1&v=1")
        XCTAssertEqual(UnivocalWakeURL.parse(url), "h1")
        let encoded = try XCTUnwrap(UnivocalWakeURL.make(scheme: "x-app", requestId: "a b&c=d", version: 2))
        XCTAssertEqual(UnivocalWakeURL.parse(encoded), "a b&c=d")

        func parse(_ s: String) -> String? { URL(string: s).flatMap(UnivocalWakeURL.parse) }
        XCTAssertEqual(parse("previewmd://univocal-connect/read?v=1&future=x&requestId=h2"), "h2", "unknown items are ignored")
        XCTAssertEqual(parse("other://univocal-connect/read?requestId=h3"), "h3", "any scheme")
        XCTAssertNil(parse("previewmd://univocal-connect/open?requestId=h1"))
        XCTAssertNil(parse("previewmd://elsewhere/read?requestId=h1"))
        XCTAssertNil(parse("previewmd://univocal-connect/read?requestId="))
        XCTAssertNil(parse("previewmd://univocal-connect/read"))
        XCTAssertNil(parse("previewmd://univocal-connect/read/extra?requestId=h1"))
        XCTAssertNil(UnivocalWakeURL.parse(URL(fileURLWithPath: "/tmp/notes.md")))

        XCTAssertNil(UnivocalWakeURL.make(scheme: "PreviewMD", requestId: "h1"))
        XCTAssertNil(UnivocalWakeURL.make(scheme: "1app", requestId: "h1"))
        XCTAssertNil(UnivocalWakeURL.make(scheme: "previewmd", requestId: ""))
        XCTAssertNil(UnivocalWakeURL.make(scheme: "previewmd", requestId: String(repeating: "x", count: 65)))
    }

    func testReadRequestWireParsing() throws {
        let now = ContinuousClock.now
        let r = try XCTUnwrap(UnivocalReadRequest(wire: ["type": "readRequest", "requestId": "h9", "trigger": "hotkey",
                                                          "prefer": "document", "answerMs": 400, "acceptedMs": 2000,
                                                          "x-future": true], linkId: 3, receivedAt: now))
        XCTAssertEqual(r.id, "h9")
        XCTAssertEqual(r.prefer, .document)
        XCTAssertEqual(r.acceptedDeadline, now.advanced(by: .milliseconds(2000)))
        let defaults = try XCTUnwrap(UnivocalReadRequest(wire: ["requestId": "h10", "trigger": "hotkey"], linkId: 3, receivedAt: now))
        XCTAssertEqual(defaults.answerMs, 300)
        XCTAssertEqual(defaults.acceptedMs, 1500)
        XCTAssertEqual(defaults.prefer, .selection)
        XCTAssertNil(UnivocalReadRequest(wire: ["requestId": "h11", "trigger": "gesture"], linkId: 3, receivedAt: now),
                     "unknown triggers are ignored (SPEC §5.11)")
        XCTAssertNil(UnivocalReadRequest(wire: ["trigger": "hotkey"], linkId: 3, receivedAt: now))
        XCTAssertEqual(UnivocalError.Code(rawValue: "unknownRequest"), .unknownRequest)
        XCTAssertEqual(UnivocalError.Code.requestAnswered.rawValue, "requestAnswered")
    }
}
