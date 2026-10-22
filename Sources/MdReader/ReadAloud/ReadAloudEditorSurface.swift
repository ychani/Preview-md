import AppKit

/// The Markdown editor as a Read Aloud surface, for Univocal's read hotkey
/// in Edit view (and in Split view while the editor has focus).
///
/// The session text is the editor's raw text, so Univocal's UTF-16 offsets
/// are `NSString` indices into it and need no mapping. Highlights are
/// layout-manager temporary attributes: they never touch the text storage,
/// the document or its undo stack. Any change to the text ends the session
/// (`onInvalidate`), as does the editor leaving its window.
@MainActor
protocol ReadAloudEditorSurface: AnyObject {
    /// The text when the surface was created (the session text).
    var text: String { get }
    /// The editor's selection (a caret has length 0).
    var selectedRange: NSRange { get }
    /// Start of the first line visible in the editor.
    func visibleStartOffset() -> Int
    /// Paints the sentence and the word (nil clears that one) and scrolls
    /// the word into view.
    func paint(word: Range<Int>?, sentence: Range<Int>?)
    /// Removes the highlights.
    func clear()
    /// Called once when the text changed or the editor went away.
    var onInvalidate: (() -> Void)? { get set }
}

@MainActor
final class TextViewReadAloudSurface: ReadAloudEditorSurface {
    let text: String
    var onInvalidate: (() -> Void)?

    private weak var textView: NSTextView?
    private let length: Int
    private var painted: [NSRange] = []
    private var invalidated = false
    nonisolated(unsafe) private var editObserver: NSObjectProtocol?

    static let sentenceColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 214 / 255, blue: 0, alpha: 0.16)
            : NSColor(srgbRed: 1, green: 214 / 255, blue: 0, alpha: 0.25)
    }
    static let wordColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 170 / 255, blue: 0, alpha: 0.45)
            : NSColor(srgbRed: 1, green: 160 / 255, blue: 0, alpha: 0.65)
    }

    init(textView: NSTextView) {
        self.textView = textView
        text = textView.string
        length = (text as NSString).length
        guard let storage = textView.textStorage else { return }
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkText() }
        }
    }

    deinit {
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
    }

    var selectedRange: NSRange {
        guard let range = textView?.selectedRange(), range.location != NSNotFound else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(location: min(range.location, length), length: range.length)
    }

    func visibleStartOffset() -> Int {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return 0 }
        var visible = textView.visibleRect
        visible.origin.x -= textView.textContainerOrigin.x
        visible.origin.y -= textView.textContainerOrigin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        guard glyphs.length > 0 else { return 0 }
        // The first line may be cut off at the top: start at the next one.
        var line = NSRange()
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &line)
        var glyph = glyphs.location
        if lineRect.minY < visible.minY - 0.5, NSMaxRange(line) < layoutManager.numberOfGlyphs {
            glyph = NSMaxRange(line)
        }
        return min(layoutManager.characterIndexForGlyph(at: glyph), length)
    }

    func paint(word: Range<Int>?, sentence: Range<Int>?) {
        checkText()
        guard !invalidated, let textView, let layoutManager = textView.layoutManager else { return }
        removePainted(layoutManager)
        if let range = clamped(sentence) {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Self.sentenceColor, forCharacterRange: range)
            painted.append(range)
        }
        if let range = clamped(word) {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Self.wordColor, forCharacterRange: range)
            painted.append(range)
        }
        if let target = clamped(word) ?? clamped(sentence) { follow(target, in: textView, layoutManager) }
    }

    func clear() {
        guard let layoutManager = textView?.layoutManager else {
            painted = []
            return
        }
        removePainted(layoutManager)
    }

    // MARK: - Private

    private func removePainted(_ layoutManager: NSLayoutManager) {
        let total = layoutManager.textStorage?.length ?? 0
        for range in painted where NSMaxRange(range) <= total {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        painted = []
    }

    private func clamped(_ range: Range<Int>?) -> NSRange? {
        guard let range, range.lowerBound >= 0, range.lowerBound < length else { return nil }
        let upper = min(range.upperBound, length)
        guard upper > range.lowerBound else { return nil }
        return NSRange(location: range.lowerBound, length: upper - range.lowerBound)
    }

    /// Keeps the spoken range on screen: when it is outside the visible
    /// rect, scrolls so it sits at 40 % of the editor's height.
    private func follow(_ range: NSRange, in textView: NSTextView, _ layoutManager: NSLayoutManager) {
        guard let container = textView.textContainer, textView.enclosingScrollView != nil else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let visible = textView.visibleRect
        guard rect.minY < visible.minY || rect.maxY > visible.maxY else { return }
        let y = max(0, rect.midY - visible.height * 0.4)
        textView.scroll(NSPoint(x: visible.minX, y: y))
    }

    /// The text changed (typing, undo, a reload from disk) or the editor
    /// left its window: the offsets no longer mean anything.
    private func checkText() {
        guard !invalidated else { return }
        guard let textView, textView.window != nil,
              let storage = textView.textStorage, storage.length == length, storage.string == text
        else {
            invalidated = true
            if let layoutManager = textView?.layoutManager { removePainted(layoutManager) }
            painted = []
            let callback = onInvalidate
            onInvalidate = nil
            callback?()
            return
        }
    }
}

/// Finds the editor's `NSTextView` behind SwiftUI's `TextEditor`.
enum EditorTextViewLocator {
    /// The editor showing `text` in `window`: the first responder if it is
    /// that editor; unless `requireFocus`, otherwise the window's text view
    /// showing `text` (or its only editable text view). Field editors (the
    /// find bar) never count.
    @MainActor
    static func textView(in window: NSWindow, showing text: String, requireFocus: Bool) -> NSTextView? {
        if let focused = window.firstResponder as? NSTextView, isEditor(focused), focused.string == text {
            return focused
        }
        if requireFocus { return nil }
        var candidates: [NSTextView] = []
        if let content = window.contentView { collect(in: content, into: &candidates) }
        if let match = candidates.first(where: { $0.string == text }) { return match }
        return candidates.count == 1 ? candidates[0] : nil
    }

    @MainActor
    private static func isEditor(_ textView: NSTextView) -> Bool {
        !textView.isFieldEditor && textView.isEditable && !textView.isHiddenOrHasHiddenAncestor
    }

    @MainActor
    private static func collect(in view: NSView, into out: inout [NSTextView]) {
        if let textView = view as? NSTextView, isEditor(textView) {
            out.append(textView)
            return
        }
        for sub in view.subviews { collect(in: sub, into: &out) }
    }
}
