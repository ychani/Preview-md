import Foundation

/// The contract between the app's Read Aloud controller and read-aloud.js in
/// the preview shell: the JavaScript calls Swift makes, and the messages the
/// page posts to `webkit.messageHandlers.readAloud`.
///
/// Offsets and ranges are UTF-16 code units into the text the page extracted
/// (Univocal Connect SPEC §7) — JavaScript string indices, so they pass
/// through untouched. Text is always JSON-encoded, never interpolated.
public enum ReadAloudBridge {
    /// The `WKScriptMessageHandler` name read-aloud.js posts to. Without it
    /// the script stays inert.
    public static let messageHandlerName = "readAloud"

    /// What read-aloud.js posts.
    public enum Message: Equatable, Sendable {
        /// The script loaded in a new page (first load or a shell reload).
        /// `highlightMode` is `"css-highlight"` or `"mark"` (diagnostics).
        case ready(highlightMode: String)
        /// Reply to `requestTextJS(request:prefer:)`: the document text,
        /// stamped with the page's `generation` for `activateJS(generation:)`,
        /// and where to start reading (0 unless `prefer` was given).
        case text(String, generation: Int, request: Int, startOffset: Int = 0)
        /// The document changed while reading: restart at `startOffset`
        /// (the current sentence, re-mapped onto `text`).
        case textChanged(String, startOffset: Int, generation: Int)
        /// The user clicked document text while reading.
        case seek(offset: Int)
        /// No text to read (`"noContent"`) or too much (`"tooLarge"`);
        /// `request` is set for a reply to `requestTextJS`.
        case error(code: String, request: Int?)
    }

    /// Decodes a `WKScriptMessage.body`. Nil for anything malformed.
    public static func parseMessage(_ body: Any) -> Message? {
        guard let dict = body as? [String: Any], let kind = dict["kind"] as? String else { return nil }
        switch kind {
        case "ready":
            return .ready(highlightMode: dict["highlightMode"] as? String ?? "")
        case "text":
            guard let text = dict["text"] as? String,
                  let generation = integer(dict["generation"]),
                  let request = integer(dict["request"]) else { return nil }
            var startOffset = 0
            if let raw = dict["startOffset"], !(raw is NSNull) {
                guard let offset = integer(raw), offset <= text.utf16.count else { return nil }
                startOffset = offset
            }
            return .text(text, generation: generation, request: request, startOffset: startOffset)
        case "textChanged":
            guard let text = dict["text"] as? String,
                  let generation = integer(dict["generation"]),
                  let offset = integer(dict["startOffset"]),
                  offset <= text.utf16.count else { return nil }
            return .textChanged(text, startOffset: offset, generation: generation)
        case "seek":
            guard let offset = integer(dict["offset"]) else { return nil }
            return .seek(offset: offset)
        case "error":
            guard let code = dict["code"] as? String else { return nil }
            return .error(code: code, request: integer(dict["request"]))
        default:
            return nil
        }
    }

    /// A non-negative integral number (JS numbers arrive as NSNumber).
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded() == double, double < 1e15 else { return nil }
        return Int(double)
    }

    // MARK: - Swift → JS

    /// Where a reading asked for by Univocal's hotkey starts (SPEC §16.12).
    public enum StartPreference: String, Sendable {
        /// The start of the preview's selection, else the first fully
        /// visible block.
        case selection
        /// The first fully visible block, even with a selection.
        case document
    }

    /// Asks the page for its text; it replies with `.text` (or `.error`)
    /// carrying `request`. With `prefer`, the reply's `startOffset` says
    /// where to start; without it (the app's own command) it is 0.
    public static func requestTextJS(request: Int, prefer: StartPreference? = nil) -> String {
        guard let prefer else { return call("requestText", String(request)) }
        return call("requestText", "\(request),{\"prefer\":\"\(prefer.rawValue)\"}")
    }

    /// Starts highlighting the text the page posted with `generation`.
    public static func activateJS(generation: Int) -> String {
        call("activate", "{\"generation\":\(generation)}")
    }

    /// Re-attaches a running session to a freshly loaded page: `text` is the
    /// session's text; the page compares it with what it renders.
    public static func reattachJS(text: String, word: Range<Int>?, sentence: Range<Int>?) -> String? {
        guard let literal = jsonArrayLiteral(text) else { return nil }
        return call("activate", "{\"text\":(\(literal))[0],\"word\":\(rangeLiteral(word)),"
                    + "\"sentence\":\(rangeLiteral(sentence))}")
    }

    /// Paints the current word and sentence (nil clears that one).
    public static func applyJS(word: Range<Int>?, sentence: Range<Int>?) -> String {
        call("apply", "{\"word\":\(rangeLiteral(word)),\"sentence\":\(rangeLiteral(sentence))}")
    }

    /// Removes the highlights; the page stays attached to the session.
    public static let clearJS = call("clear", "")

    /// Ends the session in the page: highlights, click-to-seek and
    /// scroll-follow off.
    public static let deactivateJS = call("deactivate", "")

    private static func rangeLiteral(_ range: Range<Int>?) -> String {
        guard let range, range.lowerBound >= 0 else { return "null" }
        return "[\(range.lowerBound),\(range.upperBound)]"
    }

    /// `PreviewMDReadAloud.<function>(<argument>)`, guarded so a page without
    /// read-aloud.js (or with it inert) ignores the call.
    private static func call(_ function: String, _ argument: String) -> String {
        "(typeof PreviewMDReadAloud===\"object\"&&PreviewMDReadAloud!==null"
            + "&&typeof PreviewMDReadAloud.\(function)===\"function\""
            + "&&(PreviewMDReadAloud.\(function)(\(argument)),true))"
    }

    private static func jsonArrayLiteral(_ value: String) -> String? {
        MarkdownRenderBridge.jsonArrayLiteral(value)
    }
}
