// STUB — replaced by Worker A's implementation on merge; delete this file.
//
// Compiling stand-ins for the frozen hotkey-routing API (univocal-hotkey-plan.md §A.2) so
// PreviewMD can be built and tested before the SDK lands. Bodies are trivial: no readRequest
// ever arrives, `accept`/`decline` do nothing, quiet connect reports "not connected".
// `UnivocalAppDeclaration` and `UnivocalWakeURL` are small enough to be real here because
// PreviewMD's tests validate its Info.plist and wake-URL routing with them.
//
// Beyond §A.2, PreviewMD's tests rely on one addition the real SDK must keep:
// a public memberwise `UnivocalReadRequest.init(id:trigger:prefer:answerMs:acceptedMs:receivedAt:)`
// (fake backends construct requests).

import Foundation

extension UnivocalConfiguration {
    /// Stub: stored as the "hotkey-target" capability string.
    public var hotkeyTarget: Bool {
        get { clientCapabilities.contains("hotkey-target") }
        set {
            if newValue { clientCapabilities.insert("hotkey-target") } else { clientCapabilities.remove("hotkey-target") }
        }
    }
}

public struct UnivocalReadRequest: Sendable, Hashable, Identifiable {
    public enum Trigger: String, Sendable, Codable { case hotkey }
    public enum Preference: String, Sendable, Codable { case selection, document }
    public let id: String
    public let trigger: Trigger
    public let prefer: Preference
    public let answerMs: Int
    public let acceptedMs: Int
    public let receivedAt: ContinuousClock.Instant
    public var answerDeadline: ContinuousClock.Instant { receivedAt + .milliseconds(answerMs) }
    public var acceptedDeadline: ContinuousClock.Instant { receivedAt + .milliseconds(acceptedMs) }

    public init(id: String, trigger: Trigger = .hotkey, prefer: Preference = .selection,
                answerMs: Int = 300, acceptedMs: Int = 1500,
                receivedAt: ContinuousClock.Instant = ContinuousClock.now) {
        self.id = id
        self.trigger = trigger
        self.prefer = prefer
        self.answerMs = answerMs
        self.acceptedMs = acceptedMs
        self.receivedAt = receivedAt
    }
}

public enum UnivocalDeclineReason: String, Sendable, Codable {
    case noContent, busy, notFocused, userDisabled, other
}

extension UnivocalError.Code {
    /// Stub: the real SDK adds an enum case with rawValue "unknownRequest".
    public static var unknownRequest: UnivocalError.Code { .internalError }
    /// Stub: the real SDK adds an enum case with rawValue "requestAnswered".
    public static var requestAnswered: UnivocalError.Code { .internalError }
}

extension UnivocalClient {
    public nonisolated func readRequests() -> AsyncStream<UnivocalReadRequest> {
        AsyncStream { _ in }
    }

    public func accept(_ request: UnivocalReadRequest) async throws {}

    public func read(_ request: ReadRequest, answering hotkey: UnivocalReadRequest) async throws -> ReadingSession {
        try await read(request)
    }

    public func decline(_ request: UnivocalReadRequest, reason: UnivocalDeclineReason, detail: String? = nil) async throws {}

    public func connectIfAuthorized() async throws -> UnivocalServerInfo? { nil }

    public func connectForWake(requestId: String) async throws -> UnivocalServerInfo {
        try await connect(launchIfNeeded: false)
    }
}

extension UnivocalLocator {
    public static func serverAppearances(configuration: UnivocalConfiguration) -> AsyncStream<UnivocalDiscovery> {
        AsyncStream { _ in }
    }
}

public struct UnivocalAppDeclaration: Sendable, Equatable {
    public static let infoPlistKey = "UnivocalConnect"
    public var versions: [Int]
    public var hotkeyTarget: Bool
    public var wakeURLScheme: String?

    public init(versions: [Int] = [1], hotkeyTarget: Bool, wakeURLScheme: String?) {
        self.versions = versions
        self.hotkeyTarget = hotkeyTarget
        self.wakeURLScheme = wakeURLScheme
    }

    public init?(infoDictionary: [String: Any]) {
        guard let dict = infoDictionary[Self.infoPlistKey] as? [String: Any],
              let versions = dict["Versions"] as? [Int],
              let hotkeyTarget = dict["HotkeyTarget"] as? Bool else { return nil }
        self.init(versions: versions, hotkeyTarget: hotkeyTarget, wakeURLScheme: dict["WakeURLScheme"] as? String)
    }

    public static func current(bundle: Bundle = .main) -> UnivocalAppDeclaration? {
        bundle.infoDictionary.flatMap { UnivocalAppDeclaration(infoDictionary: $0) }
    }

    public func problems(in bundle: Bundle) -> [String] {
        problems(infoDictionary: bundle.infoDictionary ?? [:])
    }

    public func problems(infoDictionary: [String: Any]) -> [String] {
        var out: [String] = []
        if !versions.contains(1) { out.append("Versions must contain 1") }
        if !hotkeyTarget { out.append("HotkeyTarget is false") }
        guard let scheme = wakeURLScheme else {
            out.append("WakeURLScheme is missing")
            return out
        }
        if scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) == nil {
            out.append("WakeURLScheme \(scheme) is not a lowercase URL scheme")
        }
        let types = infoDictionary["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        if !schemes.contains(scheme) { out.append("WakeURLScheme \(scheme) is not in CFBundleURLTypes") }
        return out
    }
}

public enum UnivocalWakeURL {
    public static let host = "univocal-connect"
    public static let path = "/read"

    public static func make(scheme: String, requestId: String, version: Int = 1) -> URL? {
        guard !requestId.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.path = path
        c.queryItems = [URLQueryItem(name: "requestId", value: requestId), URLQueryItem(name: "v", value: String(version))]
        return c.url
    }

    public static func parse(_ url: URL) -> String? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.host == host, c.path == path,
              let id = c.queryItems?.first(where: { $0.name == "requestId" })?.value, !id.isEmpty
        else { return nil }
        return id
    }
}
