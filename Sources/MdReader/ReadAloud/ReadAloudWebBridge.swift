import MdReaderCore
import WebKit

/// The calls `ReadAloudController` makes into the preview page
/// (read-aloud.js; see `ReadAloudBridge` for the contract). Tests substitute
/// a recorder.
@MainActor
protocol ReadAloudWebBridging: AnyObject {
    /// The page the next calls go to. Set from each `readAloud` message.
    var webView: WKWebView? { get set }
    /// `prefer` (a hotkey read) also asks where to start: the selection or
    /// the first visible block; nil starts at the top.
    func requestText(request: Int, prefer: ReadAloudBridge.StartPreference?)
    func activate(generation: Int)
    func reattach(text: String, word: Range<Int>?, sentence: Range<Int>?)
    func apply(word: Range<Int>?, sentence: Range<Int>?)
    func deactivate()
}

extension ReadAloudWebBridging {
    func requestText(request: Int) {
        requestText(request: request, prefer: nil)
    }
}

@MainActor
final class ReadAloudWebBridge: ReadAloudWebBridging {
    weak var webView: WKWebView?

    func requestText(request: Int, prefer: ReadAloudBridge.StartPreference?) {
        evaluate(ReadAloudBridge.requestTextJS(request: request, prefer: prefer))
    }

    func activate(generation: Int) {
        evaluate(ReadAloudBridge.activateJS(generation: generation))
    }

    func reattach(text: String, word: Range<Int>?, sentence: Range<Int>?) {
        guard let js = ReadAloudBridge.reattachJS(text: text, word: word, sentence: sentence) else { return }
        evaluate(js)
    }

    func apply(word: Range<Int>?, sentence: Range<Int>?) {
        evaluate(ReadAloudBridge.applyJS(word: word, sentence: sentence))
    }

    func deactivate() {
        evaluate(ReadAloudBridge.deactivateJS)
    }

    private func evaluate(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}
