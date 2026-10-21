// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation

/// How the client introduces itself in `hello` (SPEC §5.1).
public struct UnivocalClientIdentity: Sendable, Hashable, Codable {
    /// Reverse-DNS, stable across versions, `[A-Za-z0-9._-]{1,128}`. Grants are keyed on it.
    public var id: String
    /// Human-readable, shown in Univocal's consent prompt (≤ 64 chars).
    public var name: String
    public var version: String
    /// Informational only; Univocal trusts the code identity it resolves itself.
    public var bundleId: String?

    public init(id: String, name: String, version: String, bundleId: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.bundleId = bundleId
    }

    /// `true` when `id` matches `[A-Za-z0-9._-]{1,128}` (CONFORMANCE C2).
    public static func isValidClientId(_ id: String) -> Bool {
        guard (1...128).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || b == 0x2E || b == 0x5F || b == 0x2D
        }
    }
}

public enum UnivocalTransportKind: String, Sendable, Codable { case unixSocket, webSocket }

public struct UnivocalConfiguration: Sendable {
    public var client: UnivocalClientIdentity
    /// Univocal's bundle id; default "com.univocal.app". Env `UNIVOCAL_BUNDLE_ID` overrides the default.
    public var serverBundleId: String
    /// `<ConnectDir>`; default honours env `UNIVOCAL_CONNECT_DIR`, else
    /// ~/Library/Application Support/<Univocal|Univocal Dev>/Connect derived from `serverBundleId`
    /// **at init time** (set it again if you change `serverBundleId` afterwards).
    public var connectDirectory: URL
    /// Tried in order; default `[.unixSocket, .webSocket]`. WebSocket is used only if the
    /// discovery file advertises it and the Unix socket could not be reached.
    public var transports: [UnivocalTransportKind]
    /// Total budget for launch-on-demand: discovery polling + connect retries.
    public var launchTimeout: Duration
    /// Upper bound for the handshake, including the time the user takes to answer
    /// Univocal's consent prompt (the server's own timeout is 120 s).
    public var consentTimeout: Duration
    /// Sent in `hello.capabilities` (SPEC §11). Add "progress" to receive `.progress` events.
    public var clientCapabilities: Set<String>
    public var tokenStore: any UnivocalTokenStore
    /// Diagnostics hook. Receives ids, lengths, codes and durations — never text content.
    public var logger: (@Sendable (String) -> Void)?

    /// Resolves the installed server app for a bundle id (default: LaunchServices).
    /// Injected by tests and by hosts that locate Univocal differently.
    public var appLocator: @Sendable (_ bundleId: String) -> URL?
    /// Launches the server in the background with `--connect` (SPEC §4.3).
    /// Default: `NSWorkspace.openApplication` (`activates = false`), falling back to `open -g -b`.
    public var launcher: @Sendable (_ appURL: URL, _ bundleId: String) async throws -> Void

    public init(client: UnivocalClientIdentity) {
        self.init(client: client, environment: ProcessInfo.processInfo.environment)
    }

    /// Same as `init(client:)` with an injected environment (tests; never mutate the real one).
    public init(client: UnivocalClientIdentity, environment: [String: String]) {
        self.client = client
        let bundleId = environment["UNIVOCAL_BUNDLE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? UnivocalPaths.releaseBundleId
        self.serverBundleId = bundleId
        self.connectDirectory = Self.resolveConnectDirectory(serverBundleId: bundleId, environment: environment)
        self.transports = [.unixSocket, .webSocket]
        self.launchTimeout = .seconds(10)
        self.consentTimeout = .seconds(130)
        self.clientCapabilities = ["word-events", "sentence-events"]
        self.tokenStore = KeychainTokenStore()
        self.logger = nil
        self.appLocator = { UnivocalLocator.installedAppURL(bundleId: $0) }
        self.launcher = { url, bundleId in try await UnivocalLocator.launch(appURL: url, bundleId: bundleId) }
    }
}
