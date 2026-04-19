import Foundation

struct MarkdownFile: Identifiable, Equatable {
    let url: URL
    var content: String

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, content: String = "") {
        self.url = url
        self.content = content
    }

    static func == (lhs: MarkdownFile, rhs: MarkdownFile) -> Bool {
        lhs.url == rhs.url
    }
}
