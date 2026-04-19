import AppKit
import SwiftUI

@main
struct MdReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .onAppear {
                    appDelegate.appState = appState
                }
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
            CommandGroup(after: .toolbar) {
                Button("Preview") { appState.viewMode = .preview }
                    .keyboardShortcut("1", modifiers: [.command])
                    .disabled(appState.selectedFile == nil)
                Button("Split") { appState.viewMode = .split }
                    .keyboardShortcut("2", modifiers: [.command])
                    .disabled(appState.selectedFile == nil)
                Button("Edit") { appState.viewMode = .edit }
                    .keyboardShortcut("3", modifiers: [.command])
                    .disabled(appState.selectedFile == nil)
            }
        }
    }
}

/// NSApplicationDelegate adaptor so we can receive multi-URL Dock drops via
/// `application(_:open:)` (SwiftUI's `onOpenURL` is called once per URL and
/// can't tell a burst of drops apart from a single Finder double-click).
///
/// Dock drops can arrive before the SwiftUI scene has wired `appState` in via
/// `onAppear`; we buffer pending URLs and flush when the reference lands.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pending: [[URL]] = []
    private var _appState: AppState?

    var appState: AppState? {
        get { _appState }
        set {
            _appState = newValue
            guard let state = newValue else { return }
            let batches = pending
            pending.removeAll()
            Task { @MainActor in
                for urls in batches { Self.deliver(urls, to: state) }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let state = _appState {
            Task { @MainActor in Self.deliver(urls, to: state) }
        } else {
            pending.append(urls)
        }
    }

    @MainActor
    private static func deliver(_ urls: [URL], to state: AppState) {
        if urls.count == 1, let url = urls.first {
            state.open(url: url)
        } else if urls.count > 1 {
            state.openDroppedFiles(urls)
        }
    }
}
