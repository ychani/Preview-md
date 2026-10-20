import SwiftUI

struct EditorView: View {
    @Binding var text: String
    @AppStorage(PreviewSettings.zoomKey) private var zoom: Double = PreviewSettings.defaultZoom

    init(text: Binding<String>) {
        self._text = text
    }

    private var scale: CGFloat { CGFloat(PreviewSettings.clamp(zoom)) }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13 * scale, weight: .regular, design: .monospaced))
            .lineSpacing(3 * scale)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
