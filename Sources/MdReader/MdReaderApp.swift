import SwiftUI

@main
struct MdReaderApp: App {
    @StateObject private var appState = AppState()

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
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    appState.saveCurrentFile()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!appState.isDirty)
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
