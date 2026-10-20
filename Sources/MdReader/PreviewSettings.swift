import Foundation

/// Text zoom shared by the preview (WKWebView.pageZoom) and the editor font.
/// Stored in UserDefaults under `zoomKey`; views read it with
/// `@AppStorage(PreviewSettings.zoomKey)`. Menu commands call
/// `zoomIn()` / `zoomOut()` / `resetZoom()`.
enum PreviewSettings {
    static let zoomKey = "previewZoom"
    static let defaultZoom: Double = 1.0
    static let minZoom: Double = 0.75
    static let maxZoom: Double = 2.0
    /// Safari-like steps between min and max.
    static let zoomSteps: [Double] = [0.75, 0.85, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    static var zoom: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: zoomKey) as? Double
            return clamp(stored ?? defaultZoom)
        }
        set { UserDefaults.standard.set(clamp(newValue), forKey: zoomKey) }
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultZoom }
        return min(max(value, minZoom), maxZoom)
    }

    static var canZoomIn: Bool { zoom < maxZoom - 0.001 }
    static var canZoomOut: Bool { zoom > minZoom + 0.001 }

    static func zoomIn() {
        let current = zoom
        zoom = zoomSteps.first { $0 > current + 0.001 } ?? maxZoom
    }

    static func zoomOut() {
        let current = zoom
        zoom = zoomSteps.last { $0 < current - 0.001 } ?? minZoom
    }

    static func resetZoom() {
        zoom = defaultZoom
    }
}
