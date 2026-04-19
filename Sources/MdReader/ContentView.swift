import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)

            DetailView()
                .frame(minWidth: 480)
        }
        .toolbar { toolbarContent }
        .navigationTitle(toolbarTitle)
    }

    private var toolbarTitle: String {
        if let name = appState.selectedFile?.name {
            return appState.isDirty ? "● \(name)" : name
        }
        return "md-reader"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(appState.selectedFile?.name ?? "No file")
                    .font(.headline)
                    .foregroundStyle(appState.selectedFile == nil ? .secondary : .primary)
                if appState.isDirty {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("View Mode", selection: $appState.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .disabled(appState.selectedFile == nil)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.selectedFile == nil {
                EmptyStateView()
            } else {
                switch appState.viewMode {
                case .preview:
                    MarkdownPreviewView(markdownText: appState.editingContent)
                case .edit:
                    EditorView(text: $appState.editingContent)
                case .split:
                    HSplitView {
                        EditorView(text: $appState.editingContent)
                            .frame(minWidth: 240)
                        MarkdownPreviewView(markdownText: appState.editingContent)
                            .frame(minWidth: 240)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(appState.folderURL == nil ? "Open a Markdown file or folder to get started" : "Select a file from the sidebar")
                .font(.title3)
                .foregroundStyle(.secondary)
            if appState.folderURL == nil {
                Button("Open…") { appState.openPanel() }
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
