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
        return "Preview-MD"
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
                    PreviewPane()
                case .edit:
                    EditorView(text: $appState.editingContent)
                case .split:
                    HSplitView {
                        EditorView(text: $appState.editingContent)
                            .frame(minWidth: 240)
                        PreviewPane()
                            .frame(minWidth: 240)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct PreviewPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            MarkdownPreviewView(
                markdownText: appState.editingContent,
                onRenderComplete: { appState.markPreviewRendered() }
            )
            if appState.isLoading {
                Color(nsColor: .textBackgroundColor)
                ProgressView()
                    .controlSize(.large)
            }
        }
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 72, height: 72)
                Image(systemName: "doc.richtext")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                Text(appState.folderURL == nil ? "No file open" : "No file selected")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                Text(appState.folderURL == nil
                     ? "Open a Markdown file or folder to get started"
                     : "Select a file from the sidebar")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if appState.folderURL == nil {
                Button("Open…") { appState.openPanel() }
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
