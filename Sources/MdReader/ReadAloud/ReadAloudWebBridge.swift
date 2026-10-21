import MdReaderCore
import WebKit

/// The calls `ReadAloudController` makes into the preview page
/// (read-aloud.js; see `ReadAloudBridge` for the contract). Tests substitute
/// a recorder.
@MainActor
protocol ReadAloudWebBridging: AnyObject {
    /// The page the next calls go to. Set from each `readAloud` message.
    var webView: WKWebView? { get set }
    func requestText(request: Int)
    func activate(generation: Int)
    func reattach(text: String, word: Range<Int>?, sentence: Range<Int>?)
    func apply(word: Range<Int>?, sentence: Range<Int>?)
    func deactivate()
}

@MainActor
final class ReadAloudWebBridge: ReadAloudWebBridging {
    weak var webView: WKWebView?

    func requestText(request: Int) {
        evaluate(ReadAloudBridge.requestTextJS(request: request))
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
