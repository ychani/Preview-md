import AppKit
import MdReaderCore
import SwiftUI

@main
struct MdReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    private func recentLabel(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    /// The workspace root holding the selected file (relative paths are only
    /// meaningful inside a root).
    private var relativePathRoot: URL? {
        appState.selectedFile.flatMap { appState.workspaceRoot(containing: $0.url) }
    }

    /// Standard About panel with the bundled third-party notices as Credits.
    private static func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let url = MdReaderResources.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
            options[.credits] = NSAttributedString(string: text, attributes: attributes)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear {
                    appDelegate.appState = appState
                }
                // SwiftUI delivers a multi-file Finder/Dock open one URL at a
                // time here (and may hand part of the batch to the delegate
                // instead), so route every URL through the delegate's
                // coalescer rather than opening each one on its own.
                .onOpenURL { url in
                    appDelegate.enqueueOpen([url])
                }
                // All windows share one AppState, so route Finder / `open -a`
                // opens to the existing window instead of letting WindowGroup
                // spawn a new one per event. A window is still created when
                // none is open.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About PreviewMD") {
                    Self.showAboutPanel()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    appState.openPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Add Folder to Workspace…") {
                    appState.addFolderPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

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

                Divider()

                // ⌥⌘R / ⌥⌘C / ⇧⌥⌘C follow VS Code (Reveal in Finder, Copy
                // Path, Copy Relative Path); ⌥⌘C is also Finder's "Copy as
                // Pathname". This app has no Format menu, so ⌥⌘C does not
                // shadow TextEdit-style "Copy Style".
                Button("Reveal in Finder") {
                    if let url = appState.selectedFile?.url {
                        FileLocationActions.revealInFinder(url)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(appState.selectedFile == nil)

                Button("Copy Path") {
                    if let url = appState.selectedFile?.url {
                        FileLocationActions.copyPath(url)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(appState.selectedFile == nil)

                Button("Copy Relative Path") {
                    if let url = appState.selectedFile?.url, let root = relativePathRoot {
                        FileLocationActions.copyRelativePath(url, root: root)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(appState.selectedFile == nil || relativePathRoot == nil)
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
                Divider()
                Button("Zoom In") { PreviewSettings.zoomIn() }
                    .keyboardShortcut("+", modifiers: [.command])
                Button("Zoom Out") { PreviewSettings.zoomOut() }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Actual Size") { PreviewSettings.resetZoom() }
                    .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}

/// NSApplicationDelegate adaptor that owns external open requests (Finder
/// double-click, `open -a`, Dock drops).
///
/// A multi-file open arrives as one Apple Event, but SwiftUI splits it: the
/// scene's `onOpenURL` gets URLs one at a time and the delegate's
/// `application(_:open:)` may receive the rest. Both paths feed `enqueueOpen`,
/// which collects URLs for a short window and then routes the whole batch:
/// one URL → `AppState.open(url:)`, several → `AppState.openDroppedFiles(_:)`.
///
/// Opens can arrive before the SwiftUI scene has wired `appState` in via
/// `onAppear`; the batch stays pending until the reference lands.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// How long to keep collecting after the first URL of a burst. Long
    /// enough to span SwiftUI's per-URL callbacks, short enough to be
    /// imperceptible on a single open.
    private static let coalesceWindow: TimeInterval = 0.15

    private var pendingURLs: [URL] = []
    private var flushScheduled = false
    private var _appState: AppState?

    var appState: AppState? {
        get { _appState }
        set {
            _appState = newValue
            if newValue != nil, !pendingURLs.isEmpty { scheduleFlush() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueueOpen(urls)
    }

    /// Adds URLs to the pending batch (deduped by standardized file URL) and
    /// schedules delivery. Called on the main thread.
    func enqueueOpen(_ urls: [URL]) {
        for url in urls {
            let std = url.standardizedFileURL
            if !pendingURLs.contains(where: { $0.standardizedFileURL == std }) {
                pendingURLs.append(url)
            }
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceWindow) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        // No AppState yet (cold launch): keep the batch; the setter reschedules.
        guard let state = _appState, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        MainActor.assumeIsolated { Self.deliver(urls, to: state) }
    }

    /// Quit guard: ⌘Q with unsaved edits prompts to save/discard instead of
    /// silently dropping them. Delegate callbacks arrive on the main thread.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = _appState else { return .terminateNow }
        return MainActor.assumeIsolated {
            guard state.isDirty, let file = state.selectedFile else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Save changes to “\(file.name)” before quitting?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save and Quit")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return state.saveCurrentFile() ? .terminateNow : .terminateCancel
            case .alertSecondButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
    }

    @MainActor
    private static func deliver(_ urls: [URL], to state: AppState) {
        if urls.count == 1, let url = urls.first {
            state.open(url: url)
        } else if urls.count > 1, urls.allSatisfy(AppState.isDirectory) {
            // Several folders: open them together as the workspace.
            state.openFolders(urls)
        } else if urls.count > 1 {
            state.openDroppedFiles(urls)
        }
    }
}
