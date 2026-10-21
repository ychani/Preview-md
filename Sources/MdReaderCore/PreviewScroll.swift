import Foundation

/// Where the preview's scroll position goes when `render()` replaces its
/// content (see `MarkdownRenderBridge.renderJS(…, scroll:)`).
public enum RenderScroll: Equatable {
    /// Re-rendering the same document (typing, a reload from disk): stay put.
    case keep
    /// A different document: start at the top.
    case top
    /// The same document in a freshly loaded shell (the remote-images opt-in
    /// reloads the page): return to where the reader was.
    case restore(Double)
}

/// Decides `RenderScroll` for each render from the identity of the document
/// being rendered, so the preview starts at the top of a newly opened file
/// but keeps its place while the same file is re-rendered.
public struct PreviewScrollTracker {
    private var hasRendered = false
    private var lastDocument: URL?
    private var pendingRestore: (document: URL?, scrollY: Double)?

    public init() {}

    /// The shell is about to be reloaded for `document`; `scrollY` is the
    /// page's scroll offset just before, restored on its next render.
    public mutating func shellWillReload(document: URL?, scrollY: Double?) {
        guard let scrollY, scrollY.isFinite, scrollY > 0 else {
            pendingRestore = nil
            return
        }
        pendingRestore = (document, scrollY)
    }

    /// Call once per `render()` sent to the page.
    public mutating func scroll(forRenderOf document: URL?) -> RenderScroll {
        defer {
            hasRendered = true
            lastDocument = document
            pendingRestore = nil
        }
        let sameDocument = hasRendered && lastDocument == document
        if let pending = pendingRestore, sameDocument, pending.document == document {
            return .restore(pending.scrollY)
        }
        return sameDocument ? .keep : .top
    }
}
