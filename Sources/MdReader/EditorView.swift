import SwiftUI

struct EditorView: View {
    @Binding var text: String
    @Binding var isDirty: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .onChange(of: text) { _ in
                isDirty = true
            }
    }
}
