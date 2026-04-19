import SwiftUI

@main
struct MdReaderApp: App {
    @StateObject private var appState = AppState()

    private func recentLabel(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 820, minHeight: 520)
                .onOpenURL { url in
                    appState.open(url: url)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    appState.openPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    ForEach(appState.recentURLs, id: \.self) { url in
                        Button(recentLabel(for: url)) {
                            appState.open(url: url)
                        }
                    }
                    if !appState.recentURLs.isEmpty {
                        Divider()
                    }
                    Button("Clear Menu") {
                        appState.clearRecents()
                    }
                    .disabled(appState.recentURLs.isEmpty)
                }
                .disabled(appState.recentURLs.isEmpty)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    appState.saveCurrentFile()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!appState.isDirty)
            }
            CommandGroup(after: .textEditing) {
                Button(appState.isFindBarVisible ? "Hide Find" : "Find…") {
                    appState.toggleFindBar()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appState.selectedFile == nil)
            }
            CommandMenu("View") {
                Button("Preview") { appState.viewMode = .preview }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Split") { appState.viewMode = .split }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Edit") { appState.viewMode = .edit }
                    .keyboardShortcut("3", modifiers: [.command])
            }
        }
    }
}
