import SwiftUI

/// Toolbar Read Aloud button. It only starts a reading: while one runs it
/// shows a non-interactive "reading" speaker — Univocal's floating pill is
/// the control (pause, previous/next sentence, speed, voice, stop). Observes
/// the controller itself so word-by-word progress never re-renders the
/// window.
struct ReadAloudToolbarControls: View {
    @ObservedObject var readAloud: ReadAloudController
    /// A document is shown in Preview or Split view.
    let isDocumentReady: Bool

    var body: some View {
        if readAloud.status.isReading {
            Image(systemName: readAloud.status == .paused ? "speaker.fill" : "speaker.wave.2.fill")
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 28, minHeight: 22)
                .contentShape(Rectangle())
                .help(readAloud.helpText)
                .accessibilityLabel(readAloud.status == .paused ? "Reading Aloud, Paused" : "Reading Aloud")
                .accessibilityHint("Use Univocal's controls to pause or stop")
        } else {
            Button {
                readAloud.readAloud()
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
        readAloud.status == .unavailable ? "Get Univocal" : "Read Aloud"
    }

    private var isEnabled: Bool {
        readAloud.status == .unavailable || readAloud.canStart(documentReady: isDocumentReady)
    }

    @ViewBuilder
    private var icon: some View {
        switch readAloud.status {
        case .unavailable:
            Image(systemName: "arrow.down.circle")
        case .idle, .failed, .playing, .paused:
            Image(systemName: "speaker.wave.2")
        case .starting:
            ProgressView().controlSize(.small)
        case .awaitingConsent:
            Image(systemName: "person.badge.clock")
        case .unauthorized:
            Image(systemName: "speaker.slash")
        }
    }
}

/// Edit ▸ Read Aloud submenu. ⇧⌘R starts reading (⌥⌘R is Reveal in
/// Finder); while a reading runs the item is disabled and says the controls
/// are in Univocal — ⇧⌘R does nothing then, and there is no Stop item.
/// Univocal's ⌥⇧R pauses/resumes from anywhere. Not called "Speech": the
/// standard Edit menu may already carry AppKit's Speech submenu
/// (Start/Stop Speaking).
struct ReadAloudCommands: View {
    @ObservedObject var readAloud: ReadAloudController
    let isDocumentReady: Bool

    var body: some View {
        Button(readAloud.menuTitle) {
            readAloud.readAloud()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!readAloud.canStart(documentReady: isDocumentReady))

        if readAloud.status == .unavailable {
            Divider()
            Button("Get Univocal…") {
                readAloud.openDownloadPage()
            }
        }
    }
}
