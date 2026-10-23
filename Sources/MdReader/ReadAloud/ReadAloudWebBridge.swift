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

/// Every window shows the shared document in its own preview, so several
/// pages can be alive at once. Highlights belong to one page at a time:
/// starting or moving a session there clears the others, and `deactivate`
/// reaches every page this bridge has talked to — not only the latest.
@MainActor
final class ReadAloudWebBridge: ReadAloudWebBridging {
    weak var webView: WKWebView? {
        didSet { if let webView { pages.add(webView) } }
    }

    /// Pages seen so far (weak: a closed window's web view drops out).
    private let pages = NSHashTable<WKWebView>.weakObjects()

    func requestText(request: Int, prefer: ReadAloudBridge.StartPreference?) {
        evaluate(ReadAloudBridge.requestTextJS(request: request, prefer: prefer))
    }

    func activate(generation: Int) {
        deactivateOthers()
        evaluate(ReadAloudBridge.activateJS(generation: generation))
    }

    func reattach(text: String, word: Range<Int>?, sentence: Range<Int>?) {
        guard let js = ReadAloudBridge.reattachJS(text: text, word: word, sentence: sentence) else { return }
        deactivateOthers()
        evaluate(js)
    }

    func apply(word: Range<Int>?, sentence: Range<Int>?) {
        evaluate(ReadAloudBridge.applyJS(word: word, sentence: sentence))
    }

    func deactivate() {
        for page in pages.allObjects {
            page.evaluateJavaScript(ReadAloudBridge.deactivateJS, completionHandler: nil)
        }
    }

    private func deactivateOthers() {
        for page in pages.allObjects where page !== webView {
            page.evaluateJavaScript(ReadAloudBridge.deactivateJS, completionHandler: nil)
        }
    }

    private func evaluate(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}
