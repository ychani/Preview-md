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
        client = UnivocalClient(configuration: UnivocalConfiguration(client: identity))
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
}
