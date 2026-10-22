import Foundation
import UnivocalClient

/// What `ReadAloudController` needs from the Univocal Connect SDK. The app
/// uses `UnivocalBackend`; tests substitute a fake.
protocol ReadAloudBackend: AnyObject, Sendable {
    /// Installed / running, from LaunchServices and the discovery file.
    /// Synchronous and cheap; never launches anything.
    func availability() -> UnivocalAvailability
    /// Connection progress (launching, connecting, waiting for consent).
    /// A fresh stream per call.
    func connectionStates() -> AsyncStream<UnivocalConnectionState>
    /// Connects (launching Univocal if needed), then starts a session.
    func startReading(_ request: ReadRequest) async throws -> any ReadAloudSession

    // MARK: Univocal's read hotkey (SPEC §5.11, §16)

    /// Requests from Univocal to read in place of its own panel. One
    /// consumer per app; the stream outlives disconnects.
    func readRequests() -> AsyncStream<UnivocalReadRequest>
    /// `readAccepted`: buys time (up to the request's `acceptedMs`) while
    /// the page extracts its text.
    func accept(_ request: UnivocalReadRequest) async throws
    /// `readDecline`: Univocal reads in its own panel instead (or asks
    /// another connection, for `notFocused`).
    func decline(_ request: UnivocalReadRequest, reason: UnivocalDeclineReason, detail: String?) async throws
    /// Answers `hotkey` with a session over the live connection; throws
    /// `unknownRequest` when Univocal already gave up on it.
    func startReading(_ request: ReadRequest, answering hotkey: UnivocalReadRequest) async throws
        -> any ReadAloudSession
    /// Quiet connect (SPEC §16.9): only with a stored grant and Univocal
    /// already running; never launches it or prompts. True when connected.
    func connectIfAuthorized() async throws -> Bool
    /// Univocal opened the wake URL (SPEC §16.5): connect without launching,
    /// naming the request; the request then arrives on `readRequests()`.
    func connectForWake(requestId: String) async throws
    /// Yields whenever Univocal starts (and once now if it is running).
    func serverAppearances() -> AsyncStream<UnivocalDiscovery>
}

/// One reading session (the SDK's `ReadingSession`).
protocol ReadAloudSession: AnyObject, Sendable {
    var id: String { get }
    var events: AsyncStream<ReadingEvent> { get }
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func seek(toUTF16Offset offset: Int) async throws
}

extension ReadingSession: ReadAloudSession {}

/// The real backend: one `UnivocalClient` for the app's lifetime. The SDK's
/// configuration defaults honour `UNIVOCAL_CONNECT_DIR` and
/// `UNIVOCAL_BUNDLE_ID`, so manual QA can point the app at the mock server
/// without app-level settings.
final class UnivocalBackend: ReadAloudBackend {
    static let clientID = "com.narnarlabs.previewmd"

    let client: UnivocalClient

    init() {
        let info = Bundle.main.infoDictionary
        let identity = UnivocalClientIdentity(
            id: Self.clientID,
            name: "PreviewMD",
            version: info?["CFBundleShortVersionString"] as? String ?? "dev",
            bundleId: Bundle.main.bundleIdentifier)
        var configuration = UnivocalConfiguration(client: identity)
        // Answer Univocal's read hotkey while PreviewMD is frontmost (SPEC §16).
        configuration.hotkeyTarget = true
        client = UnivocalClient(configuration: configuration)
    }

    func availability() -> UnivocalAvailability {
        UnivocalLocator.availability(configuration: client.configuration)
    }

    func connectionStates() -> AsyncStream<UnivocalConnectionState> {
        client.stateUpdates()
    }

    func startReading(_ request: ReadRequest) async throws -> any ReadAloudSession {
        try await client.read(request)
    }

    func readRequests() -> AsyncStream<UnivocalReadRequest> {
        client.readRequests()
    }

    func accept(_ request: UnivocalReadRequest) async throws {
        try await client.accept(request)
    }

    func decline(_ request: UnivocalReadRequest, reason: UnivocalDeclineReason, detail: String?) async throws {
        try await client.decline(request, reason: reason, detail: detail)
    }

    func startReading(_ request: ReadRequest, answering hotkey: UnivocalReadRequest) async throws
        -> any ReadAloudSession {
        try await client.read(request, answering: hotkey)
    }

    func connectIfAuthorized() async throws -> Bool {
        try await client.connectIfAuthorized() != nil
    }

    func connectForWake(requestId: String) async throws {
        _ = try await client.connectForWake(requestId: requestId)
    }

    func serverAppearances() -> AsyncStream<UnivocalDiscovery> {
        UnivocalLocator.serverAppearances(configuration: client.configuration)
    }
}
