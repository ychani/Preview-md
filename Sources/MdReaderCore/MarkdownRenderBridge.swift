import Foundation

/// Helpers for sending markdown text into the preview WebView safely.
public enum MarkdownRenderBridge {
    /// Builds a JavaScript expression that calls `render(<escapedMarkdown>)` in the
    /// preview WebView. Uses JSONSerialization to guarantee the string is a valid JS
    /// literal regardless of backticks, quotes, backslashes, or embedded newlines.
    public static func renderJS(for markdown: String) -> String? {
        guard let data = try? JSONSerialization.data(
                withJSONObject: [markdown], options: []),
              let arr = String(data: data, encoding: .utf8) else { return nil }
        // `arr` is ["..."]; evaluating (arr)[0] yields the safely-encoded string.
        return "render((\(arr))[0])"
    }
}
