import SwiftUI

@main
struct MdReaderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open Folder…") {
                    appState.openFolderPanel()
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
        }
    }
}
