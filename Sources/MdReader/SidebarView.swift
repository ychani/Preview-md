import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showUnsavedAlert = false
    @State private var pendingFile: MarkdownFile?

    var body: some View {
        VStack(spacing: 0) {
            // Folder header
            HStack {
                if let folder = appState.folderURL {
                    Text(folder.lastPathComponent)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No folder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    appState.openPanel()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Open file or folder…")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if appState.files.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Open a folder\nto see Markdown files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List(appState.files, selection: Binding(
                    get: { appState.selectedFile?.id },
                    set: { newID in
                        guard let id = newID,
                              let file = appState.files.first(where: { $0.id == id }),
                              file != appState.selectedFile else { return }
                        attemptSelect(file)
                    }
                )) { file in
                    FileRowView(file: file, isSelected: appState.selectedFile?.id == file.id)
                        .tag(file.id)
                        .onTapGesture { attemptSelect(file) }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 180)
        .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
            Button("Save", role: .none) {
                appState.saveCurrentFile()
                if let f = pendingFile { appState.selectFile(f) }
                pendingFile = nil
            }
            Button("Discard", role: .destructive) {
                if let f = pendingFile { appState.selectFile(f) }
                pendingFile = nil
            }
            Button("Cancel", role: .cancel) {
                pendingFile = nil
            }
        } message: {
            Text("Do you want to save your changes to \"\(appState.selectedFile?.name ?? "")\" before switching files?")
        }
    }

    private func attemptSelect(_ file: MarkdownFile) {
        if appState.isDirty {
            pendingFile = file
            showUnsavedAlert = true
        } else {
            appState.selectFile(file)
        }
    }
}

private struct FileRowView: View {
    let file: MarkdownFile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .imageScale(.small)
                .foregroundStyle(isSelected ? .primary : .secondary)
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}
