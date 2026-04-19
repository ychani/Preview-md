import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showUnsavedAlert = false
    @State private var pendingFile: MarkdownFile?

    var body: some View {
        VStack(spacing: 0) {
            // Folder header
            HStack(spacing: 6) {
                if let folder = appState.folderURL {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(folder.lastPathComponent)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("FILES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.8)
                }
                Spacer()
                Button {
                    appState.openPanel()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Open file or folder…")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()

            if appState.files.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("No Markdown files")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
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

    private var displayName: String {
        file.name.hasSuffix(".md")
            ? String(file.name.dropLast(3))
            : file.name
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(displayName)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 1)
    }
}
