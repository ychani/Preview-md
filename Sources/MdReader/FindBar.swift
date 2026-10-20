import SwiftUI

struct FindBar: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Find", text: Binding(
                get: { appState.findQuery },
                set: { appState.updateFindQuery($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180, maxWidth: 280)
            .focused($isFieldFocused)
            .onSubmit { appState.findNext() }
            // Escape while typing closes the bar even if the field editor
            // consumes the key before the Close button's shortcut sees it.
            .onExitCommand { appState.hideFindBar() }
            .accessibilityLabel("Find in Document")

            Text(matchLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .leading)

            Button {
                appState.findPrev()
            } label: {
                Label("Previous Match", systemImage: "chevron.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(appState.findMatchCount == 0)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Previous match (⇧⌘G)")

            Button {
                appState.findNext()
            } label: {
                Label("Next Match", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(appState.findMatchCount == 0)
            .keyboardShortcut("g", modifiers: .command)
            .help("Next match (⌘G)")

            Spacer()

            Button {
                appState.hideFindBar()
            } label: {
                Label("Close Find Bar", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear { isFieldFocused = true }
    }

    private var matchLabel: String {
        if appState.findQuery.isEmpty { return "" }
        if appState.findMatchCount == 0 { return "No matches" }
        return "\(appState.findCurrentIndex) of \(appState.findMatchCount)"
    }
}
