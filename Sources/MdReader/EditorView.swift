import SwiftUI

struct EditorView: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .lineSpacing(3)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
