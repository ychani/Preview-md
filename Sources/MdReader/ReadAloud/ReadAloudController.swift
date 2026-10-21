import AppKit
import MdReaderCore
import UnivocalClient
import WebKit

/// Read Aloud: Univocal speaks the previewed document and reports the word
/// and sentence it is on; the preview highlights them (read-aloud.js).
///
/// Flow on play: ask the page for its text → `backend.startReading` (which
/// connects, launching Univocal and waiting for the user's approval in
/// Univocal if needed) → forward the session's word/sentence events to the
/// page. Reading stops on a document switch, on Edit view, and on ⇧⌘.; a
/// document edit mid-session restarts at the re-mapped current sentence.
///
/// Inert until the user acts: nothing launches Univocal or connects to it
/// before a click, and without Univocal installed the only affordance is
/// "Get Univocal".
@MainActor
final class ReadAloudController: ObservableObject {
    enum Status: Equatable {
        /// Univocal is not installed: the toolbar offers "Get Univocal".
        case unavailable
        case idle
        /// Launching, connecting or loading; optional detail from Univocal.
        case starting(String?)
        /// Univocal is asking the user to allow PreviewMD.
        case awaitingConsent
        /// Univocal didn't allow PreviewMD (or access was removed); the
        /// message explains, and the next click asks again.
        case unauthorized(String)
        case playing
        case paused
        /// The last attempt failed; cleared by the next action.
        case failed(String)

        /// A session is starting or running (Stop applies).
        var isActive: Bool {
            switch self {
            case .starting, .awaitingConsent, .playing, .paused: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status

    /// The range being read. Not published: they change several times a
    /// second and only the page shows them.
    private(set) var currentWord: Range<Int>?
    private(set) var currentSentence: Range<Int>?
    /// The page's highlight mechanism ("css-highlight" or "mark"), for
    /// diagnostics.
    private(set) var highlightMode: String?

    /// The document's display name, sent to Univocal as `meta.title`.
    var documentTitle: () -> String? = { nil }

    let bridge: ReadAloudWebBridging
    private let backend: ReadAloudBackend
    private let openURL: (URL) -> Void

    /// Bumped whenever a session (or an attempt) is abandoned; work started
    /// for an older token is dropped.
    private var sessionToken = 0
    private var requestCounter = 0
    /// The `requestText` the page has not answered yet.
    private var pendingRequest: Int?
    /// The page that posted the text being read. Its generation stamps are
    /// only meaningful to that page; any other page gets the text itself.
    private var textSource: ObjectIdentifier?
    private var startTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var session: (any ReadAloudSession)?
    private var sessionText: String?
    private var sessionGeneration: Int?
    /// An edit arrived while paused: restart there on resume instead.
    private var pendingRestart: (text: String, startOffset: Int, generation: Int)?
    /// A non-fatal session error, reported if the session then ends.
    private var lastSessionError: UnivocalError?
    private var serverCapabilities: Set<String>?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    /// How long the page may take to answer `requestText`.
    static let textTimeout: Duration = .seconds(5)

    init(
        backend: ReadAloudBackend = UnivocalBackend(),
        bridge: ReadAloudWebBridging? = nil,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.backend = backend
        self.bridge = bridge ?? ReadAloudWebBridge()
        self.openURL = openURL
        status = backend.availability() == .notInstalled ? .unavailable : .idle
        // The user may have just installed (or removed) Univocal.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAvailability() }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    // MARK: - Actions

    /// Play from idle, pause while playing, resume while paused. Without
    /// Univocal installed, opens its download page.
    func toggle() {
        switch status {
        case .unavailable, .idle, .failed, .unauthorized:
            refreshAvailability(force: true)
            if status == .unavailable {
                openDownloadPage()
            } else {
                start()
            }
        case .playing:
            control { try await $0.pause() }
        case .paused:
            if let restart = pendingRestart {
                restartSession(text: restart.text, startOffset: restart.startOffset,
                               generation: restart.generation)
            } else {
                control { try await $0.resume() }
            }
        case .starting, .awaitingConsent:
            break
        }
    }

    /// Stops reading (or the attempt to start) and clears the highlights.
    func stop() {
        guard status.isActive || session != nil || pendingRequest != nil else { return }
        let old = session
        endSession()
        if let old { Task { try? await old.stop() } }
        status = .idle
        refreshAvailability()
    }

    /// The selected document changed (or closed).
    func documentDidChange() {
        stop()
    }

    func seek(toUTF16Offset offset: Int) {
        guard let session, status == .playing || status == .paused else { return }
        if let serverCapabilities, !serverCapabilities.contains("seek") { return }
        Task { try? await session.seek(toUTF16Offset: offset) }
    }

    func openDownloadPage() {
        openURL(UnivocalLocator.downloadURL)
    }

    /// Re-checks whether Univocal is installed. Leaves a running session and
    /// a shown failure alone unless `force`.
    func refreshAvailability(force: Bool = false) {
        guard !status.isActive else { return }
        let installed = backend.availability() != .notInstalled
        if !installed {
            status = .unavailable
        } else if status == .unavailable || (force && status != .idle) {
            status = .idle
        }
    }

    // MARK: - Page messages

    func handle(_ message: ReadAloudBridge.Message, from webView: WKWebView?) {
        if let webView { bridge.webView = webView }
        switch message {
        case .ready(let mode):
            // A new page (the shell loaded or reloaded): generation stamps
            // from the old one mean nothing here.
            highlightMode = mode
            textSource = nil
            if let request = pendingRequest {
                bridge.requestText(request: request)
            } else if session != nil, let text = sessionText {
                bridge.reattach(text: text, word: currentWord, sentence: currentSentence)
            }
        case .text(let text, let generation, let request):
            guard request == pendingRequest else { return }
            pendingRequest = nil
            textSource = webView.map(ObjectIdentifier.init)
            begin(text: text, startOffset: 0, generation: generation, replacing: nil)
        case .textChanged(let text, let startOffset, let generation):
            guard sessionText != nil else { return }
            textSource = webView.map(ObjectIdentifier.init)
            if status == .paused {
                pendingRestart = (text, startOffset, generation)
            } else {
                restartSession(text: text, startOffset: startOffset, generation: generation)
            }
        case .seek(let offset):
            seek(toUTF16Offset: offset)
        case .error(let code, let request):
            guard (request != nil && request == pendingRequest) || (request == nil && sessionText != nil)
            else { return }
            let old = session
            endSession()
            if let old { Task { try? await old.stop() } }
            if code == "noContent" && request == nil {
                // Everything was deleted mid-session: nothing left to read.
                status = .idle
            } else {
                status = .failed(code == "tooLarge"
                                 ? "This document is too long to read aloud"
                                 : "There is no text to read in this document")
            }
        }
    }

    // MARK: - Sessions

    private func start() {
        guard bridge.webView != nil else {
            status = .failed("Show the preview to read aloud")
            return
        }
        endSession()
        requestCounter &+= 1
        let request = requestCounter
        pendingRequest = request
        status = .starting(nil)
        observeConnection()
        bridge.requestText(request: request)
        let token = sessionToken
        Task { [weak self] in
            try? await Task.sleep(for: Self.textTimeout)
            guard let self, token == self.sessionToken, self.pendingRequest == request else { return }
            self.endSession()
            self.status = .failed("The preview isn't ready")
        }
    }

    /// Starts a session on `text`; with `replacing`, stops that one first.
    private func begin(text: String, startOffset: Int, generation: Int,
                       replacing old: (any ReadAloudSession)?) {
        let token = sessionToken
        var request = ReadRequest(text: text)
        request.startOffset = startOffset
        request.title = documentTitle()
        sessionText = text
        sessionGeneration = generation
        currentWord = nil
        currentSentence = nil
        if case .starting = status {} else { status = .starting(nil) }
        observeConnection()
        startTask = Task { [weak self, backend] in
            if let old { try? await old.stop() }
            do {
                let session = try await backend.startReading(request)
                guard let self, token == self.sessionToken else {
                    try? await session.stop()
                    return
                }
                self.attach(session, token: token)
            } catch {
                guard let self, token == self.sessionToken else { return }
                self.fail(with: error)
            }
        }
    }

    private func attach(_ session: any ReadAloudSession, token: Int) {
        self.session = session
        startTask = nil
        if let generation = sessionGeneration, let webView = bridge.webView,
           ObjectIdentifier(webView) == textSource {
            bridge.activate(generation: generation)
        } else if let text = sessionText {
            bridge.reattach(text: text, word: nil, sentence: nil)
        }
        eventTask = Task { [weak self] in
            for await event in session.events {
                guard let self, token == self.sessionToken else { return }
                self.handle(event)
            }
            // The stream finished without `.ended` (should not happen).
            guard let self, token == self.sessionToken else { return }
            self.finish(.error)
        }
    }

    private func handle(_ event: ReadingEvent) {
        switch event {
        case .state(.loading, let detail):
            status = .starting(detail)
        case .state(.playing, _):
            status = .playing
        case .state(.paused, _):
            status = .paused
        case .sentence(let range):
            currentSentence = range
            currentWord = nil
            bridge.apply(word: nil, sentence: range)
        case .word(let range):
            currentWord = range
            bridge.apply(word: range, sentence: currentSentence)
        case .progress, .rate:
            break
        case .error(let error):
            lastSessionError = error
        case .ended(let reason, _):
            finish(reason)
        }
    }

    private func finish(_ reason: EndReason) {
        let error = lastSessionError
        endSession()
        switch reason {
        case .finished, .stopped, .preempted:
            // Preempted: Univocal (or another app) started reading; nothing
            // to report.
            status = .idle
            refreshAvailability()
        case .revoked:
            status = .unauthorized(Self.revokedMessage)
        case .error:
            if error?.code == .unauthorized {
                status = .unauthorized(Self.revokedMessage)
            } else {
                status = .failed(Self.message(for: error))
            }
        }
    }

    private func restartSession(text: String, startOffset: Int, generation: Int) {
        let old = session
        endSession()
        status = .starting(nil)
        begin(text: text, startOffset: startOffset, generation: generation, replacing: old)
    }

    private func fail(with error: Error) {
        let error = error as? UnivocalError
        endSession()
        switch error?.code {
        case .notInstalled?:
            status = .unavailable
        case .consentDenied?:
            status = .unauthorized(Self.consentMessage(reason: error?.reason))
        case .consentTimedOut?:
            status = .unauthorized(Self.consentMessage(reason: "timeout"))
        case .unauthorized?:
            status = .unauthorized(Self.revokedMessage)
        default:
            status = .failed(Self.message(for: error))
        }
    }

    /// Forgets the current session or attempt (the caller sets `status`).
    private func endSession() {
        sessionToken &+= 1
        pendingRequest = nil
        startTask?.cancel()
        startTask = nil
        eventTask?.cancel()
        eventTask = nil
        session = nil
        sessionText = nil
        sessionGeneration = nil
        pendingRestart = nil
        lastSessionError = nil
        currentWord = nil
        currentSentence = nil
        bridge.deactivate()
    }

    private func control(_ action: @escaping @Sendable (any ReadAloudSession) async throws -> Void) {
        guard let session else { return }
        // Failures (e.g. the session just ended) surface as events.
        Task { try? await action(session) }
    }

    /// Follows the SDK's connection state while starting: launching,
    /// connecting, waiting for the user's approval in Univocal.
    private func observeConnection() {
        guard connectionTask == nil else { return }
        let states = backend.connectionStates()
        connectionTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                self.connectionChanged(state)
            }
            self?.connectionTask = nil
        }
    }

    private func connectionChanged(_ state: UnivocalConnectionState) {
        let starting = session == nil && (startTask != nil || pendingRequest != nil)
        switch state {
        case .connected(let info):
            serverCapabilities = info.capabilities
            if status == .awaitingConsent { status = .starting(nil) }
        case .awaitingConsent:
            if starting { status = .awaitingConsent }
        case .launching:
            if starting { status = .starting("Starting Univocal…") }
        case .connecting:
            if starting, status != .awaitingConsent { status = .starting("Connecting to Univocal…") }
        case .disconnected:
            serverCapabilities = nil
        }
    }

    // MARK: - Text

    private static let revokedMessage =
        "PreviewMD's access was removed in Univocal. Try again in a few minutes."

    static func consentMessage(reason: String?) -> String {
        switch reason {
        case "timeout": return "No answer in Univocal. Click to ask again."
        case "disabled": return "Univocal doesn't allow other apps. Turn that on in Univocal's settings."
        case "rateLimited": return "Too many requests. Wait a minute, then try again."
        default: return "Univocal didn't allow PreviewMD. Click to ask again."
        }
    }

    static func message(for error: UnivocalError?) -> String {
        guard let error else { return "Reading stopped unexpectedly" }
        switch error.code {
        case .launchTimedOut: return "Univocal didn't start"
        case .notRunning: return "Univocal isn't running"
        case .unsupportedVersion: return "Update Univocal to read aloud from PreviewMD"
        case .transportFailure, .disconnected: return "Lost the connection to Univocal"
        case .textTooLarge, .limitExceeded: return "This document is too long to read aloud"
        case .engineUnavailable:
            return error.message.isEmpty ? "Univocal's voice isn't ready yet" : error.message
        case .engineError: return "Univocal couldn't read this document"
        default: return error.message.isEmpty ? "Reading stopped unexpectedly" : error.message
        }
    }

    // MARK: - Presentation

    /// Title of the play/pause command.
    var toggleTitle: String {
        switch status {
        case .playing: return "Pause Reading"
        case .paused: return "Resume Reading"
        default: return "Read Aloud"
        }
    }

    /// Menu title: the toggle, or what is going on instead.
    var menuTitle: String {
        switch status {
        case .awaitingConsent: return "Waiting for Approval in Univocal…"
        case .failed(let message): return "Read Aloud — \(message)"
        default: return toggleTitle
        }
    }

    /// Toolbar tooltip.
    var helpText: String {
        switch status {
        case .unavailable: return "Read aloud needs Univocal — click to get it"
        case .idle: return "Read Aloud"
        case .starting(let detail): return detail ?? "Starting…"
        case .awaitingConsent: return "Waiting for approval in Univocal…"
        case .unauthorized(let message): return message
        case .playing: return "Pause Reading"
        case .paused: return "Resume Reading"
        case .failed(let message): return "Read Aloud — \(message)"
        }
    }

    /// Whether play/pause applies now (the menu item's enabled state).
    func canToggle(documentReady: Bool) -> Bool {
        switch status {
        case .unavailable, .starting, .awaitingConsent: return false
        case .playing, .paused: return true
        case .idle, .failed, .unauthorized: return documentReady
        }
    }
}
