// STUB — replaced by Worker A's implementation on merge; delete this file.
//
// A compiling copy of the frozen public API (plan §A.3) so the PreviewMD Read
// Aloud client builds before the real SDK lands. Bodies are trivial: the app
// sees Univocal as "not installed" and every operation throws `notInstalled`.
//
// One addition beyond §A.3 that PreviewMD's tests rely on:
// `UnivocalError.init(code:message:fatal:reason:sessionId:)` is public.

import Foundation

// MARK: Identity & configuration

public struct UnivocalClientIdentity: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var version: String
    public var bundleId: String?
    public init(id: String, name: String, version: String, bundleId: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.bundleId = bundleId
    }
}

public enum UnivocalTransportKind: String, Sendable, Codable { case unixSocket, webSocket }

public struct UnivocalConfiguration: Sendable {
    public var client: UnivocalClientIdentity
    public var serverBundleId: String
    public var connectDirectory: URL
    public var transports: [UnivocalTransportKind]
    public var launchTimeout: Duration
    public var consentTimeout: Duration
    public var clientCapabilities: Set<String>
    public var tokenStore: any UnivocalTokenStore
    public var logger: (@Sendable (String) -> Void)?

    public init(client: UnivocalClientIdentity) {
        self.client = client
        let env = ProcessInfo.processInfo.environment
        serverBundleId = env["UNIVOCAL_BUNDLE_ID"] ?? "com.univocal.app"
        connectDirectory = Self.resolveConnectDirectory(serverBundleId: serverBundleId, environment: env)
        transports = [.unixSocket, .webSocket]
        launchTimeout = .seconds(10)
        consentTimeout = .seconds(130)
        clientCapabilities = ["word-events", "sentence-events"]
        tokenStore = InMemoryTokenStore()
        logger = nil
    }

    public static func resolveConnectDirectory(
        serverBundleId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let dir = environment["UNIVOCAL_CONNECT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let folder = serverBundleId.hasSuffix(".dev") ? "Univocal Dev" : "Univocal"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(folder)/Connect", isDirectory: true)
    }
}

// MARK: Token storage

public protocol UnivocalTokenStore: Sendable {
    func token(forServer serverBundleId: String) async throws -> String?
    func setToken(_ token: String?, forServer serverBundleId: String) async throws
}

public struct KeychainTokenStore: UnivocalTokenStore {
    public init(service: String = "com.univocal.connect", accessGroup: String? = nil) {}
    public func token(forServer serverBundleId: String) async throws -> String? { nil }
    public func setToken(_ token: String?, forServer serverBundleId: String) async throws {}
}

public actor InMemoryTokenStore: UnivocalTokenStore {
    public private(set) var all: [String: String]
    public init(initial: [String: String] = [:]) { all = initial }
    public func token(forServer serverBundleId: String) async throws -> String? { all[serverBundleId] }
    public func setToken(_ token: String?, forServer serverBundleId: String) async throws {
        all[serverBundleId] = token
    }
}

// MARK: Availability & discovery

public enum UnivocalAvailability: Sendable, Equatable {
    case notInstalled
    case installed(appURL: URL, running: Bool)
}

public struct UnivocalDiscovery: Sendable, Equatable, Codable {
    public var versions: [Int]; public var socketPath: String; public var webSocketURL: URL?
    public var pid: Int32; public var serverName: String; public var serverVersion: String; public var serverBundleId: String
}

public enum UnivocalLocator {
    public static func availability(configuration: UnivocalConfiguration) -> UnivocalAvailability { .notInstalled }
    public static func discovery(in connectDirectory: URL) -> UnivocalDiscovery? { nil }
    public static func installedAppURL(bundleId: String) -> URL? { nil }
    public static let downloadURL = URL(string: "https://univocalapp.com")!
}

// MARK: Connection

public struct UnivocalServerInfo: Sendable, Equatable {
    public var name: String; public var version: String; public var bundleId: String
    public var protocolVersion: Int
    public var capabilities: Set<String>
    public var maxFrameBytes: Int; public var maxTextBytes: Int
    public var rateRange: ClosedRange<Double>
    public var grantIdentity: String
    public var transport: UnivocalTransportKind
}

public enum UnivocalConnectionState: Sendable, Equatable {
    case disconnected
    case launching
    case connecting
    case awaitingConsent
    case connected(UnivocalServerInfo)
}

public struct UnivocalError: Error, Sendable, Equatable {
    public enum Code: String, Sendable, Codable {
        case protocolError, unsupportedVersion, unauthorized, unknownType, invalidArgument, sessionExists,
             noSession, notOwner, busy, invalidOffset, limitExceeded, rateLimited, engineUnavailable,
             engineError, slowConsumer, internalError = "internal"
        case notInstalled, notRunning, launchTimedOut, consentDenied, consentTimedOut, disconnected,
             transportFailure, textTooLarge, sessionEnded
    }
    public var code: Code
    public var message: String
    public var fatal: Bool
    public var reason: String?
    public var sessionId: String?

    public init(code: Code, message: String = "", fatal: Bool = false,
                reason: String? = nil, sessionId: String? = nil) {
        self.code = code
        self.message = message
        self.fatal = fatal
        self.reason = reason
        self.sessionId = sessionId
    }
}

public actor UnivocalClient {
    public nonisolated let configuration: UnivocalConfiguration
    public init(configuration: UnivocalConfiguration) { self.configuration = configuration }

    public var state: UnivocalConnectionState { .disconnected }
    public var lastError: UnivocalError? { nil }
    public nonisolated func stateUpdates() -> AsyncStream<UnivocalConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.disconnected)
            continuation.finish()
        }
    }

    public func connect(launchIfNeeded: Bool = true) async throws -> UnivocalServerInfo {
        throw UnivocalError(code: .notInstalled, message: "Univocal is not installed")
    }
    public func disconnect() async {}
    public func forgetAuthorization() async throws {}
    public func read(_ request: ReadRequest) async throws -> ReadingSession {
        throw UnivocalError(code: .notInstalled, message: "Univocal is not installed")
    }
    public func listVoices() async throws -> [UnivocalVoice] {
        throw UnivocalError(code: .notInstalled, message: "Univocal is not installed")
    }
    public func ping() async throws -> Duration {
        throw UnivocalError(code: .notInstalled, message: "Univocal is not installed")
    }
}

// MARK: Sessions

public struct ReadRequest: Sendable {
    public var text: String
    public var sessionId: String
    public var language: String?
    public var voice: String?
    public var rate: Double?
    public var startOffset: Int
    public var preempt: Bool
    public var showPanel: Bool
    public var title: String?
    public init(text: String) {
        self.text = text
        sessionId = UUID().uuidString
        startOffset = 0
        preempt = true
        showPanel = false
    }
}

public struct UnivocalVoice: Sendable, Equatable, Codable { public var id: String; public var name: String; public var lang: String? }

public enum PlaybackState: String, Sendable, Codable { case loading, playing, paused }
public enum EndReason: String, Sendable, Codable { case finished, stopped, preempted, error, revoked }

public enum ReadingEvent: Sendable, Equatable {
    case state(PlaybackState, detail: String?)
    case sentence(Range<Int>)
    case word(Range<Int>)
    case progress(offset: Int)
    case rate(Double)
    case error(UnivocalError)
    case ended(EndReason, by: String?)
}

public final class ReadingSession: Sendable {
    public let id: String
    public let textUTF16Count: Int
    public let events: AsyncStream<ReadingEvent>
    public var isEnded: Bool { true }

    private init() { fatalError("stub") }

    public func pause() async throws { fatalError("stub") }
    public func resume() async throws { fatalError("stub") }
    public func stop() async throws { fatalError("stub") }
    public func seek(toUTF16Offset offset: Int) async throws { fatalError("stub") }
    public func setRate(_ rate: Double) async throws { fatalError("stub") }
}

// MARK: Offsets helper

public enum UTF16Offsets {
    public static func range(_ r: Range<Int>, in text: String) -> Range<String.Index>? { nil }
    public static func nsRange(_ r: Range<Int>) -> NSRange { NSRange(location: r.lowerBound, length: r.count) }
    public static func utf16Count(_ s: String) -> Int { s.utf16.count }
}
