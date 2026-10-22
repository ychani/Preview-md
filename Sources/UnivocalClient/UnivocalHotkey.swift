// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import os

// MARK: - Incoming hotkey requests (SPEC §5.11)

/// A server-initiated `readRequest`: Univocal's read hotkey was pressed while this
/// app was frontmost and asks the app to read in place of Univocal's own panel.
/// Answer it exactly once with `UnivocalClient.read(_:answering:)` or
/// `UnivocalClient.decline(_:reason:detail:)`, optionally preceded by
/// `UnivocalClient.accept(_:)` when the text is not already in hand.
public struct UnivocalReadRequest: Sendable, Hashable, Identifiable {
    public enum Trigger: String, Sendable, Codable { case hotkey }
    public enum Preference: String, Sendable, Codable { case selection, document }

    /// The server's `requestId`.
    public let id: String
    public let trigger: Trigger
    public let prefer: Preference
    /// Milliseconds within which some answer must arrive at the server (≥ 300 per spec).
    public let answerMs: Int
    /// Milliseconds within which the `read` must arrive after `readAccepted` (≥ 1500 per spec).
    public let acceptedMs: Int
    /// When the SDK decoded the frame.
    public let receivedAt: ContinuousClock.Instant
    /// The connection that delivered the request (0 = none, e.g. a request built by a test double).
    let linkId: Int

    /// `receivedAt + answerMs`. The server measures from when it *sent* the request, so
    /// this is a slightly optimistic local estimate; aim well below it.
    public var answerDeadline: ContinuousClock.Instant { receivedAt.advanced(by: .milliseconds(answerMs)) }
    /// `receivedAt + acceptedMs` (same caveat as `answerDeadline`).
    public var acceptedDeadline: ContinuousClock.Instant { receivedAt.advanced(by: .milliseconds(acceptedMs)) }

    /// For test doubles and fake backends. A request built here belongs to no connection:
    /// `UnivocalClient` answers to it throw `disconnected`.
    public init(id: String, trigger: Trigger = .hotkey, prefer: Preference = .selection,
                answerMs: Int = 300, acceptedMs: Int = 1500,
                receivedAt: ContinuousClock.Instant = ContinuousClock.now) {
        self.init(id: id, trigger: trigger, prefer: prefer, answerMs: answerMs, acceptedMs: acceptedMs,
                  receivedAt: receivedAt, linkId: 0)
    }

    init(id: String, trigger: Trigger, prefer: Preference, answerMs: Int, acceptedMs: Int,
         receivedAt: ContinuousClock.Instant, linkId: Int) {
        self.id = id
        self.trigger = trigger
        self.prefer = prefer
        self.answerMs = answerMs
        self.acceptedMs = acceptedMs
        self.receivedAt = receivedAt
        self.linkId = linkId
    }

    /// Parses a `readRequest` frame; `nil` for an unknown `trigger` or a missing `requestId`
    /// (SPEC §5.11: clients MUST ignore triggers they do not know).
    init?(wire msg: JSONObject, linkId: Int, receivedAt: ContinuousClock.Instant) {
        guard let rid = msg.string("requestId"), !rid.isEmpty,
              let trigger = Trigger(rawValue: msg.string("trigger") ?? "") else { return nil }
        let answer = max(1, msg.int("answerMs") ?? 300)
        self.init(id: rid, trigger: trigger,
                  prefer: Preference(rawValue: msg.string("prefer") ?? "") ?? .selection,
                  answerMs: answer, acceptedMs: max(answer, msg.int("acceptedMs") ?? 1500),
                  receivedAt: receivedAt, linkId: linkId)
    }
}

/// `readDecline.reason` (SPEC §5.11).
public enum UnivocalDeclineReason: String, Sendable, Codable {
    /// Nothing to read: no document, empty text.
    case noContent
    /// The app cannot read now (a modal, mid-save, a start already in flight).
    case busy
    /// This connection does not own the app's key window; the server may ask another one.
    case notFocused
    /// The user turned the feature off in the app.
    case userDisabled
    /// Anything else (e.g. an editing surface with no highlight mapping); add a `detail`.
    case other
}

/// Bookkeeping for one request on one connection (actor-confined in `UnivocalClient`).
enum HotkeyRequestState: Sendable, Equatable {
    case pending
    case accepted
    case answered
}

/// Multi-observer fan-out for `readRequests()`. Unlike `StateBroadcaster` it has no
/// current value: a request is delivered only to the streams alive when it arrives.
final class RequestBroadcaster: Sendable {
    private let observers = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<UnivocalReadRequest>.Continuation]())

    func makeStream() -> AsyncStream<UnivocalReadRequest> {
        let (stream, cont) = AsyncStream<UnivocalReadRequest>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        cont.onTermination = { [weak self] _ in
            _ = self?.observers.withLock { $0.removeValue(forKey: id) }
        }
        observers.withLock { $0[id] = cont }
        return stream
    }

    /// Delivers `request` to every live stream; returns how many received it.
    @discardableResult
    func broadcast(_ request: UnivocalReadRequest) -> Int {
        observers.withLock { obs in
            for c in obs.values { c.yield(request) }
            return obs.count
        }
    }
}

// MARK: - Info.plist declaration (SPEC §16.5, Appendix B)

/// The `UnivocalConnect` dictionary an app declares in its `Info.plist` so Univocal
/// can wake it for a hotkey press while it is running but not connected.
///
/// ```xml
/// <key>UnivocalConnect</key>
/// <dict>
///     <key>Versions</key>        <array><integer>1</integer></array>
///     <key>HotkeyTarget</key>    <true/>
///     <key>WakeURLScheme</key>   <string>myapp</string>
/// </dict>
/// ```
/// The scheme must also be registered in the same bundle's `CFBundleURLTypes`.
public struct UnivocalAppDeclaration: Sendable, Equatable {
    public static let infoPlistKey = "UnivocalConnect"
    static let versionsKey = "Versions"
    static let hotkeyTargetKey = "HotkeyTarget"
    static let wakeURLSchemeKey = "WakeURLScheme"

    public var versions: [Int]
    public var hotkeyTarget: Bool
    public var wakeURLScheme: String?

    public init(versions: [Int] = [1], hotkeyTarget: Bool, wakeURLScheme: String?) {
        self.versions = versions
        self.hotkeyTarget = hotkeyTarget
        self.wakeURLScheme = wakeURLScheme
    }

    /// Parses the `UnivocalConnect` dict out of a bundle's info dictionary. `nil` when the
    /// dict is absent, `Versions` is missing or not an array of integers, `HotkeyTarget` is
    /// present but not a boolean, or `WakeURLScheme` is present but not a string.
    /// An absent `HotkeyTarget` reads as `false`.
    public init?(infoDictionary: [String: Any]) {
        guard let dict = infoDictionary[Self.infoPlistKey] as? [String: Any],
              let rawVersions = dict[Self.versionsKey] as? [Any] else { return nil }
        var versions: [Int] = []
        for v in rawVersions {
            guard let n = v as? NSNumber, !Self.isBoolean(n), CFNumberIsFloatType(n) == false else { return nil }
            versions.append(n.intValue)
        }
        var hotkey = false
        if let h = dict[Self.hotkeyTargetKey] {
            guard let n = h as? NSNumber, Self.isBoolean(n) else { return nil }
            hotkey = n.boolValue
        }
        var scheme: String?
        if let s = dict[Self.wakeURLSchemeKey] {
            guard let str = s as? String else { return nil }
            scheme = str
        }
        self.init(versions: versions, hotkeyTarget: hotkey, wakeURLScheme: scheme)
    }

    /// `bundle`'s declaration (`nil` in tests and CLIs without one).
    public static func current(bundle: Bundle = .main) -> UnivocalAppDeclaration? {
        bundle.infoDictionary.flatMap { UnivocalAppDeclaration(infoDictionary: $0) }
    }

    /// Human-readable problems; empty when the declaration is valid for hotkey routing.
    public func problems(in bundle: Bundle) -> [String] {
        problems(infoDictionary: bundle.infoDictionary ?? [:])
    }

    /// Human-readable problems; empty when valid for hotkey routing: `versions` empty or
    /// without a version this SDK speaks, `hotkeyTarget` false, scheme missing, not
    /// matching `^[a-z][a-z0-9+.-]*$`, or not registered in the dictionary's
    /// `CFBundleURLTypes[].CFBundleURLSchemes`.
    public func problems(infoDictionary: [String: Any]) -> [String] {
        var out: [String] = []
        if versions.isEmpty {
            out.append("\(Self.infoPlistKey).\(Self.versionsKey) is empty")
        } else if !versions.contains(where: UnivocalWire.protocolVersions.contains) {
            out.append("\(Self.infoPlistKey).\(Self.versionsKey) \(versions) has no version this SDK speaks (\(UnivocalWire.protocolVersions))")
        }
        if !hotkeyTarget {
            out.append("\(Self.infoPlistKey).\(Self.hotkeyTargetKey) is not true")
        }
        guard let scheme = wakeURLScheme, !scheme.isEmpty else {
            out.append("\(Self.infoPlistKey).\(Self.wakeURLSchemeKey) is missing")
            return out
        }
        if !UnivocalWakeURL.isValidScheme(scheme) {
            out.append("\(Self.infoPlistKey).\(Self.wakeURLSchemeKey) \"\(scheme)\" is not a lowercase URL scheme (^[a-z][a-z0-9+.-]*$)")
        }
        let registered = Self.registeredSchemes(infoDictionary)
        if !registered.contains(scheme.lowercased()) {
            out.append("URL scheme \"\(scheme)\" is not registered in CFBundleURLTypes (registered: \(registered.isEmpty ? "none" : registered.sorted().joined(separator: ", ")))")
        }
        return out
    }

    /// Lower-cased `CFBundleURLTypes[].CFBundleURLSchemes[]`.
    static func registeredSchemes(_ info: [String: Any]) -> Set<String> {
        let types = info["CFBundleURLTypes"] as? [Any] ?? []
        var out = Set<String>()
        for t in types {
            guard let d = t as? [String: Any], let schemes = d["CFBundleURLSchemes"] as? [Any] else { continue }
            for s in schemes { if let s = s as? String { out.insert(s.lowercased()) } }
        }
        return out
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}

// MARK: - Wake URL (SPEC §16.5)

/// `<scheme>://univocal-connect/read?requestId=<id>&v=<version>` — the URL Univocal opens
/// (with `activates = false`) to wake a declared app for a pending hotkey request.
///
/// On receipt the app must not open a window, change document or activate itself; it
/// calls `UnivocalClient.connectForWake(requestId:)` and answers the `readRequest`.
public enum UnivocalWakeURL {
    public static let host = "univocal-connect"
    public static let path = "/read"
    static let requestIdItem = "requestId"
    static let versionItem = "v"

    /// `nil` if the scheme is not `^[a-z][a-z0-9+.-]*$` or the id is empty / longer than 64.
    public static func make(scheme: String, requestId: String, version: Int = 1) -> URL? {
        guard isValidScheme(scheme), !requestId.isEmpty, requestId.count <= 64 else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.path = path
        c.queryItems = [URLQueryItem(name: requestIdItem, value: requestId),
                        URLQueryItem(name: versionItem, value: String(version))]
        return c.url
    }

    /// The `requestId` if `url` is a wake URL for any scheme (host and path match, non-empty
    /// `requestId`; unknown query items are ignored); `nil` otherwise. Pure.
    public static func parse(_ url: URL) -> String? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.isEmpty == false,
              c.host?.lowercased() == host,
              c.path == path,
              let id = c.queryItems?.first(where: { $0.name == requestIdItem })?.value,
              !id.isEmpty
        else { return nil }
        return id
    }

    static func isValidScheme(_ s: String) -> Bool {
        guard let first = s.utf8.first, first >= 0x61, first <= 0x7A else { return false }
        return s.utf8.allSatisfy { b in
            (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2B || b == 0x2E || b == 0x2D
        }
    }
}
