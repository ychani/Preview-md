// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation

/// File names and limits for `<ConnectDir>` (SPEC §3.1, §4.2).
public enum UnivocalPaths {
    public static let socketFileName = "connect.sock"
    public static let discoveryFileName = "connect.json"
    /// `sun_path` holds 104 bytes on Darwin including the terminating NUL.
    public static let maxSocketPathBytes = 103
    public static let releaseBundleId = "com.univocal.app"
    public static let devBundleId = "com.univocal.app.dev"

    public static func wellKnownSocketPath(in connectDirectory: URL) -> String {
        connectDirectory.appendingPathComponent(socketFileName).path
    }

    public static func discoveryFileURL(in connectDirectory: URL) -> URL {
        connectDirectory.appendingPathComponent(discoveryFileName)
    }

    /// `true` when `path` fits in `sockaddr_un.sun_path`.
    public static func socketPathFits(_ path: String) -> Bool {
        path.utf8.count <= maxSocketPathBytes
    }

    /// The real home directory of the current user (not a sandbox container).
    static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `kill(pid, 0)` liveness: alive unless the call fails with `ESRCH`.
    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}

/// The parsed discovery file `<ConnectDir>/connect.json` (SPEC §4.2).
///
/// Its `Codable` form is the on-disk format (`socket`, `ws.url`, `server.{…}`),
/// so the same type reads and writes the file.
public struct UnivocalDiscovery: Sendable, Equatable, Codable {
    public var versions: [Int]
    public var socketPath: String
    public var webSocketURL: URL?
    public var pid: Int32
    public var serverName: String
    public var serverVersion: String
    public var serverBundleId: String

    public init(versions: [Int] = UnivocalWire.protocolVersions, socketPath: String, webSocketURL: URL? = nil,
                pid: Int32, serverName: String, serverVersion: String, serverBundleId: String) {
        self.versions = versions
        self.socketPath = socketPath
        self.webSocketURL = webSocketURL
        self.pid = pid
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.serverBundleId = serverBundleId
    }

    private enum Keys: String, CodingKey { case `protocol`, versions, socket, ws, pid, server, startedAt }
    private enum WSKeys: String, CodingKey { case url }
    private enum ServerKeys: String, CodingKey { case name, version, bundleId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let proto = try c.decode(String.self, forKey: .protocol)
        guard proto == UnivocalWire.protocolName else {
            throw DecodingError.dataCorruptedError(forKey: .protocol, in: c, debugDescription: "not univocal-connect")
        }
        versions = try c.decode([Int].self, forKey: .versions)
        socketPath = try c.decode(String.self, forKey: .socket)
        if c.contains(.ws), let ws = try? c.nestedContainer(keyedBy: WSKeys.self, forKey: .ws) {
            webSocketURL = try? ws.decode(URL.self, forKey: .url)
        } else {
            webSocketURL = nil
        }
        pid = try c.decode(Int32.self, forKey: .pid)
        let s = try c.nestedContainer(keyedBy: ServerKeys.self, forKey: .server)
        serverName = (try? s.decode(String.self, forKey: .name)) ?? "Univocal"
        serverVersion = (try? s.decode(String.self, forKey: .version)) ?? ""
        serverBundleId = (try? s.decode(String.self, forKey: .bundleId)) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(UnivocalWire.protocolName, forKey: .protocol)
        try c.encode(versions, forKey: .versions)
        try c.encode(socketPath, forKey: .socket)
        if let webSocketURL {
            var ws = c.nestedContainer(keyedBy: WSKeys.self, forKey: .ws)
            try ws.encode(webSocketURL.absoluteString, forKey: .url)
        }
        try c.encode(pid, forKey: .pid)
        var s = c.nestedContainer(keyedBy: ServerKeys.self, forKey: .server)
        try s.encode(serverName, forKey: .name)
        try s.encode(serverVersion, forKey: .version)
        try s.encode(serverBundleId, forKey: .bundleId)
    }
}

extension UnivocalConfiguration {
    /// `<ConnectDir>` for a server bundle id: env `UNIVOCAL_CONNECT_DIR` wins;
    /// otherwise `~/Library/Application Support/Univocal Dev/Connect` for a
    /// `.dev` bundle id and `…/Univocal/Connect` for everything else.
    public static func resolveConnectDirectory(
        serverBundleId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["UNIVOCAL_CONNECT_DIR"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        let folder = serverBundleId.hasSuffix(".dev") ? "Univocal Dev" : "Univocal"
        return UnivocalPaths.realHomeDirectory()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("Connect", isDirectory: true)
    }
}
