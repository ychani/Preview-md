import SwiftUI

/// Toolbar play/pause button (plus Stop while reading). Observes the
/// controller itself so word-by-word progress never re-renders the window.
struct ReadAloudToolbarControls: View {
    @ObservedObject var readAloud: ReadAloudController
    /// A document is shown in Preview or Split view.
    let isDocumentReady: Bool

    var body: some View {
        HStack(spacing: 0) {
            if readAloud.status.isActive {
                Button {
                    readAloud.stop()
                } label: {
                    Label("Stop Reading", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
                .help("Stop Reading")
            }
            Button {
                readAloud.toggle()
            } label: {
                Label {
                    Text(title)
                } icon: {
                    icon
                }
                .labelStyle(.iconOnly)
            }
            .help(readAloud.helpText)
            .accessibilityLabel(title)
            .disabled(!isEnabled)
        }
    }

    private var title: String {
        readAloud.status == .unavailable ? "Get Univocal" : readAloud.toggleTitle
    }

    private var isEnabled: Bool {
        switch readAloud.status {
        case .unavailable: return true
        case .starting, .awaitingConsent: return false
        default: return readAloud.canToggle(documentReady: isDocumentReady)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch readAloud.status {
        case .unavailable:
            Image(systemName: "arrow.down.circle")
        case .idle, .failed:
            Image(systemName: "speaker.wave.2")
        case .starting:
            ProgressView().controlSize(.small)
        case .awaitingConsent:
            Image(systemName: "person.badge.clock")
        case .unauthorized:
            Image(systemName: "speaker.slash")
        case .playing:
            Image(systemName: "pause.fill")
        case .paused:
            Image(systemName: "play.fill")
        }
    }
}

/// Edit ▸ Read Aloud submenu. ⇧⌘R plays/pauses, ⇧⌘. stops (⌥⌘R is Reveal
/// in Finder). Not called "Speech": the standard Edit menu may already carry
/// AppKit's Speech submenu (Start/Stop Speaking).
struct ReadAloudCommands: View {
    @ObservedObject var readAloud: ReadAloudController
    let isDocumentReady: Bool

    var body: some View {
        Button(readAloud.menuTitle) {
            readAloud.toggle()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!readAloud.canToggle(documentReady: isDocumentReady))

        Button("Stop Reading") {
            readAloud.stop()
        }
        .keyboardShortcut(".", modifiers: [.command, .shift])
        .disabled(!readAloud.status.isActive)

        if readAloud.status == .unavailable {
            Divider()
            Button("Get Univocal…") {
                readAloud.openDownloadPage()
            }
        }
    }
}
