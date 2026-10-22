import AppKit
import UnivocalClient
import XCTest
@testable import MdReader

/// The app side of Univocal's hotkey: the editor as a highlight surface,
/// finding the editor's text view, the wake URL's routing, and the
/// Info.plist declaration Univocal reads (SPEC §16.5, Appendix B).
@MainActor
final class ReadAloudHotkeyAppTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    /// A scrollable editor in an offscreen window, like SwiftUI's TextEditor.
    private func makeEditor(_ text: String, size: NSSize = NSSize(width: 400, height: 200)) -> NSTextView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.allowsUndo = true
        textView.string = text
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.frame = NSRect(origin: .zero, size: size)
        self.window = window
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    private func background(_ textView: NSTextView, at index: Int) -> (NSColor?, NSRange) {
        var range = NSRange()
        let value = textView.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: index, effectiveRange: &range) as? NSColor
        return (value, range)
    }

    // MARK: Editor surface

    func testPaintsTemporaryAttributesWithoutTouchingTheDocument() {
        let textView = makeEditor("Hello world. Second one.")
        let surface = TextViewReadAloudSurface(textView: textView)
        XCTAssertEqual(surface.text, "Hello world. Second one.")

        surface.paint(word: 6..<11, sentence: 0..<12)
        var (color, range) = background(textView, at: 7)
        XCTAssertEqual(color, TextViewReadAloudSurface.wordColor)
        XCTAssertEqual(range, NSRange(location: 6, length: 5))
        (color, range) = background(textView, at: 2)
        XCTAssertEqual(color, TextViewReadAloudSurface.sentenceColor)
        XCTAssertNil(background(textView, at: 15).0)

        // Next word, next sentence: the old ranges are gone.
        surface.paint(word: 13..<19, sentence: 13..<24)
        XCTAssertNil(background(textView, at: 7).0)
        XCTAssertEqual(background(textView, at: 14).0, TextViewReadAloudSurface.wordColor)
        XCTAssertEqual(background(textView, at: 21).0, TextViewReadAloudSurface.sentenceColor)

        // Out-of-range offsets are ignored, not trapped.
        surface.paint(word: 40..<50, sentence: nil)
        XCTAssertNil(background(textView, at: 14).0)

        // The document itself never changed: no attributes, no undo.
        surface.paint(word: 0..<5, sentence: 0..<12)
        var stored = false
        textView.textStorage!.enumerateAttribute(
            .backgroundColor, in: NSRange(location: 0, length: textView.textStorage!.length)
        ) { value, _, _ in if value != nil { stored = true } }
        XCTAssertFalse(stored)
        XCTAssertFalse(textView.undoManager?.canUndo ?? false)
        XCTAssertEqual(textView.string, "Hello world. Second one.")

        surface.clear()
        XCTAssertNil(background(textView, at: 2).0)
        XCTAssertNil(background(textView, at: 0).0)
    }

    func testAnEditInvalidatesOnceAndClears() {
        let textView = makeEditor("Hello world. Second one.")
        let surface = TextViewReadAloudSurface(textView: textView)
        var calls = 0
        surface.onInvalidate = { calls += 1 }
        surface.paint(word: 0..<5, sentence: 0..<12)
        textView.insertText("Oh, ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(calls, 1)
        XCTAssertNil(background(textView, at: 6).0, "highlights removed")
        textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        surface.paint(word: 0..<5, sentence: nil)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(background(textView, at: 1).0, "nothing painted on a changed text")
    }

    func testAProgrammaticChangeInvalidates() {
        let textView = makeEditor("One.")
        let surface = TextViewReadAloudSurface(textView: textView)
        var calls = 0
        surface.onInvalidate = { calls += 1 }
        textView.string = "Reloaded from disk."
        XCTAssertEqual(calls, 1)
    }

    func testSelectionAndVisibleStart() throws {
        let lines = (0..<200).map { "Line number \($0)" }
        let text = lines.joined(separator: "\n")
        let textView = makeEditor(text)
        textView.setSelectedRange(NSRange(location: 12, length: 4))
        let surface = TextViewReadAloudSurface(textView: textView)
        XCTAssertEqual(surface.selectedRange, NSRange(location: 12, length: 4))
        XCTAssertEqual(surface.visibleStartOffset(), 0)

        // Scroll so line 50 is cut off at the top: start at line 51.
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let line50 = (text as NSString).range(of: "Line number 50\n")
        let glyph = layoutManager.glyphIndexForCharacter(at: line50.location)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        textView.scroll(NSPoint(x: 0, y: rect.minY + textView.textContainerOrigin.y + rect.height / 2))
        XCTAssertEqual(surface.visibleStartOffset(), (text as NSString).range(of: "Line number 51\n").location)
    }

    func testFollowsTheWordOutOfView() throws {
        let lines = (0..<200).map { "Line number \($0)" }
        let text = lines.joined(separator: "\n")
        let textView = makeEditor(text)
        let surface = TextViewReadAloudSurface(textView: textView)
        let target = (text as NSString).range(of: "number 150")
        surface.paint(word: target.location..<NSMaxRange(target), sentence: nil)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let glyphs = layoutManager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
        rect.origin.y += textView.textContainerOrigin.y
        XCTAssertTrue(textView.visibleRect.contains(rect), "\(rect) not in \(textView.visibleRect)")
        // Already visible: no scroll.
        let before = textView.visibleRect
        let next = (text as NSString).range(of: "number 151")
        surface.paint(word: next.location..<NSMaxRange(next), sentence: nil)
        XCTAssertEqual(textView.visibleRect, before)
    }

    // MARK: Locator

    func testLocatesTheEditorBehindTheWindow() throws {
        let textView = makeEditor("# Doc\n\nBody.")
        let window = try XCTUnwrap(self.window)
        // Not focused: only found when focus isn't required.
        window.makeFirstResponder(nil)
        XCTAssertNil(EditorTextViewLocator.textView(in: window, showing: textView.string, requireFocus: true))
        XCTAssertTrue(EditorTextViewLocator.textView(in: window, showing: textView.string, requireFocus: false)
                      === textView)
        // Focused.
        window.makeFirstResponder(textView)
        XCTAssertTrue(EditorTextViewLocator.textView(in: window, showing: textView.string, requireFocus: true)
                      === textView)
        // Focused, but showing something else.
        XCTAssertNil(EditorTextViewLocator.textView(in: window, showing: "Other", requireFocus: true))
        // A non-editable text view is not the editor.
        textView.isEditable = false
        XCTAssertNil(EditorTextViewLocator.textView(in: window, showing: textView.string, requireFocus: false))
    }

    func testFieldEditorsAreNotTheEditor() throws {
        let textView = makeEditor("Body.")
        let window = try XCTUnwrap(self.window)
        let scroll = try XCTUnwrap(window.contentView)
        let container = NSView(frame: scroll.frame)
        window.contentView = container
        container.addSubview(scroll)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        field.stringValue = "Body."
        container.addSubview(field)
        window.makeFirstResponder(field)
        if let fieldEditor = window.firstResponder as? NSTextView {
            XCTAssertTrue(fieldEditor.isFieldEditor)
        }
        XCTAssertNil(EditorTextViewLocator.textView(in: window, showing: "Body.", requireFocus: true))
        XCTAssertTrue(EditorTextViewLocator.textView(in: window, showing: "Body.", requireFocus: false) === textView)
    }

    // MARK: Wake URL routing

    func testWakeURLsGoToReadAloudAndNeverToTheOpenQueue() {
        let delegate = AppDelegate()
        var woken: [String] = []
        delegate.wakeHandler = { woken.append($0) }
        let file = URL(fileURLWithPath: "/tmp/notes.md")
        delegate.application(NSApplication.shared, open: [
            URL(string: "previewmd://univocal-connect/read?requestId=h1&v=1&future=x")!,
            file,
            URL(string: "previewmd://something-else")!,
        ])
        XCTAssertEqual(woken, ["h1"])
        XCTAssertEqual(delegate.pendingURLs, [file])

        // The same through SwiftUI's onOpenURL path.
        delegate.route([URL(string: "previewmd://univocal-connect/read?requestId=h2&v=1")!])
        XCTAssertEqual(woken, ["h1", "h2"])
        XCTAssertEqual(delegate.pendingURLs, [file])
    }

    func testGetURLAppleEventRoutesTheWake() {
        let delegate = AppDelegate()
        var woken: [String] = []
        delegate.wakeHandler = { woken.append($0) }
        func event(_ url: String) -> NSAppleEventDescriptor {
            let e = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
                                           eventID: AEEventID(kAEGetURL), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
            e.setParam(NSAppleEventDescriptor(string: url), forKeyword: keyDirectObject)
            return e
        }
        delegate.handleGetURL(event("previewmd://univocal-connect/read?requestId=g1&v=1"),
                              withReplyEvent: NSAppleEventDescriptor.null())
        delegate.handleGetURL(event("previewmd://univocal-connect/other?requestId=g2"),
                              withReplyEvent: NSAppleEventDescriptor.null())
        delegate.handleGetURL(event("not a url"), withReplyEvent: NSAppleEventDescriptor.null())
        XCTAssertEqual(woken, ["g1"])
        XCTAssertTrue(delegate.pendingURLs.isEmpty)
    }

    // MARK: Info.plist declaration

    private static let packaging = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("packaging")

    private func plist(_ name: String) throws -> [String: Any] {
        let url = Self.packaging.appendingPathComponent(name)
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any], "\(url.path)")
    }

    func testInfoPlistDeclaresTheHotkeyTarget() throws {
        let info = try plist("Info.plist")
        let declaration = try XCTUnwrap(UnivocalAppDeclaration(infoDictionary: info))
        XCTAssertEqual(declaration.problems(infoDictionary: info), [])
        XCTAssertEqual(declaration.versions, [1])
        XCTAssertTrue(declaration.hotkeyTarget)
        XCTAssertEqual(declaration.wakeURLScheme, "previewmd")
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        XCTAssertEqual(types.first?["CFBundleURLName"] as? String, "com.narnarlabs.previewmd.url")
        XCTAssertEqual(types.first?["LSHandlerRank"] as? String, "Owner")

        // The URL Univocal opens comes back as the request id.
        let wake = try XCTUnwrap(UnivocalWakeURL.make(scheme: "previewmd", requestId: "h3a9"))
        XCTAssertEqual(UnivocalWakeURL.parse(wake), "h3a9")
    }

    func testQuickLookPlistIsUntouched() throws {
        let ql = try plist("QLInfo.plist")
        XCTAssertNil(ql[UnivocalAppDeclaration.infoPlistKey])
        XCTAssertNil(ql["CFBundleURLTypes"])
    }
}
