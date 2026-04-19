import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.isFindBarVisible {
                FindBar()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HSplitView {
                if appState.showSidebar {
                    SidebarView()
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                }

                DetailView()
                    .frame(minWidth: 420)

                if appState.showTOC {
                    TOCView(entries: appState.tocEntries) { entry in
                        appState.scrollToHeading(entry.id)
                    }
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.isFindBarVisible)
        .animation(.easeInOut(duration: 0.15), value: appState.showSidebar)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle(toolbarTitle)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var collected: [(Int, URL)] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            _ = provider.loadDataRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { data, _ in
                defer { group.leave() }
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                collected.append((index, url))
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            let ordered = collected.sorted { $0.0 < $1.0 }.map { $0.1 }
            guard !ordered.isEmpty else { return }
            appState.openDroppedFiles(ordered)
        }
        return true
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

        ToolbarItem(placement: .primaryAction) {
            Button {
                appState.showTOC.toggle()
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .help(appState.showTOC ? "Hide Table of Contents" : "Show Table of Contents")
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
                onRenderComplete: { appState.markPreviewRendered() },
                onTOCUpdate: { entries in appState.tocEntries = entries },
                scrollRequest: appState.scrollRequest,
                onWebViewReady: { webView in appState.previewWebView = webView }
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
