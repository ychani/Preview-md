import Foundation

/// A Markdown file shown in the sidebar. Contents are not cached here — the
/// selected file's text lives in `AppState.editingContent`.
struct MarkdownFile: Identifiable, Equatable {
    let url: URL

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url
    }
}
