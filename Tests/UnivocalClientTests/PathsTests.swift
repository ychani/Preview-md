// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient
import UnivocalMock

final class PathsTests: UnivocalTestCase {

    // MARK: ConnectDir resolution (S1) — injected environment, never the real one

    func testConnectDirectoryHonoursEnvironmentOverride() {
        let url = UnivocalConfiguration.resolveConnectDirectory(serverBundleId: "com.univocal.app",
                                                                environment: ["UNIVOCAL_CONNECT_DIR": "/tmp/uc-qa"])
        XCTAssertEqual(url.path, "/tmp/uc-qa")
        let tilde = UnivocalConfiguration.resolveConnectDirectory(serverBundleId: "com.univocal.app",
                                                                  environment: ["UNIVOCAL_CONNECT_DIR": "~/x"])
        XCTAssertFalse(tilde.path.contains("~"))
    }

    func testConnectDirectoryReleaseAndDevDefaults() {
        let release = UnivocalConfiguration.resolveConnectDirectory(serverBundleId: "com.univocal.app", environment: [:])
        XCTAssertTrue(release.path.hasSuffix("/Library/Application Support/Univocal/Connect"), release.path)
        let dev = UnivocalConfiguration.resolveConnectDirectory(serverBundleId: "com.univocal.app.dev", environment: [:])
        XCTAssertTrue(dev.path.hasSuffix("/Library/Application Support/Univocal Dev/Connect"), dev.path)
    }

    func testConfigurationDefaultsAndBundleIdOverride() {
        let id = UnivocalClientIdentity(id: "com.example.app", name: "App", version: "1")
        let c = UnivocalConfiguration(client: id, environment: ["UNIVOCAL_BUNDLE_ID": "com.univocal.app.dev"])
        XCTAssertEqual(c.serverBundleId, "com.univocal.app.dev")
        XCTAssertTrue(c.connectDirectory.path.hasSuffix("Univocal Dev/Connect"))
        XCTAssertEqual(c.transports, [.unixSocket, .webSocket])
        XCTAssertEqual(c.launchTimeout, .seconds(10))
        XCTAssertEqual(c.consentTimeout, .seconds(130))
        XCTAssertEqual(c.clientCapabilities, ["word-events", "sentence-events"])
        XCTAssertTrue(c.tokenStore is KeychainTokenStore)
        let plain = UnivocalConfiguration(client: id, environment: [:])
        XCTAssertEqual(plain.serverBundleId, "com.univocal.app")
    }

    func testClientIdValidation() {
        XCTAssertTrue(UnivocalClientIdentity.isValidClientId("com.narnarlabs.previewmd"))
        XCTAssertTrue(UnivocalClientIdentity.isValidClientId("sh.example-cli_2"))
        XCTAssertFalse(UnivocalClientIdentity.isValidClientId(""))
        XCTAssertFalse(UnivocalClientIdentity.isValidClientId("has space"))
        XCTAssertFalse(UnivocalClientIdentity.isValidClientId("é"))
        XCTAssertFalse(UnivocalClientIdentity.isValidClientId(String(repeating: "a", count: 129)))
    }

    func testSocketPathLimit() {
        XCTAssertTrue(UnivocalPaths.socketPathFits("/" + String(repeating: "a", count: 102)))
        XCTAssertFalse(UnivocalPaths.socketPathFits("/" + String(repeating: "a", count: 103)))
    }

    // MARK: Discovery file (S8, C1)

    func testDiscoveryRoundTripAndStalePid() throws {
        let alive = UnivocalDiscovery(socketPath: "/tmp/x.sock", webSocketURL: URL(string: "ws://127.0.0.1:5/connect"),
                                      pid: getpid(), serverName: "U", serverVersion: "1", serverBundleId: "com.univocal.app")
        try JSONEncoder().encode(alive).write(to: UnivocalPaths.discoveryFileURL(in: dir))
        XCTAssertEqual(UnivocalLocator.discovery(in: dir), alive)

        var stale = alive
        stale.pid = Int32.max   // no such process → ESRCH
        try JSONEncoder().encode(stale).write(to: UnivocalPaths.discoveryFileURL(in: dir))
        XCTAssertNil(UnivocalLocator.discovery(in: dir), "a dead pid means not running")
    }

    func testDiscoveryRejectsForeignProtocolAndMissingFile() throws {
        XCTAssertNil(UnivocalLocator.discovery(in: dir))
        let json = #"{"protocol":"something-else","versions":[1],"socket":"/tmp/s","pid":\#(getpid()),"server":{"name":"x"}}"#
        try Data(json.utf8).write(to: UnivocalPaths.discoveryFileURL(in: dir))
        XCTAssertNil(UnivocalLocator.discovery(in: dir))
    }

    func testDiscoveryParsesSpecExampleShape() throws {
        let json = """
        {"protocol":"univocal-connect","versions":[1],"socket":"/tmp/s.sock","ws":{"url":"ws://127.0.0.1:52133/connect"},
         "pid":\(getpid()),"server":{"name":"Univocal","version":"0.5.0","bundleId":"com.univocal.app"},
         "startedAt":"2026-10-21T18:02:11Z","x-future":true}
        """
        try Data(json.utf8).write(to: UnivocalPaths.discoveryFileURL(in: dir))
        let d = try XCTUnwrap(UnivocalLocator.discovery(in: dir))
        XCTAssertEqual(d.socketPath, "/tmp/s.sock")
        XCTAssertEqual(d.webSocketURL?.port, 52133)
        XCTAssertEqual(d.serverVersion, "0.5.0")
    }

    // MARK: Mock server files (S1, S2, S8)

    func testMockCreatesPrivateDirectorySocketAndDiscovery() async throws {
        // A stale socket file must be unlinked before bind.
        FileManager.default.createFile(atPath: UnivocalPaths.wellKnownSocketPath(in: dir), contents: Data("stale".utf8))
        chmod(dir.path, 0o755)
        let server = try await startServer()
        let socket = await server.socketPath
        XCTAssertEqual(socket, UnivocalPaths.wellKnownSocketPath(in: dir))
        XCTAssertEqual(try mode(dir.path), 0o700)
        XCTAssertEqual(try mode(socket), 0o600)
        XCTAssertEqual(try mode(UnivocalPaths.discoveryFileURL(in: dir).path), 0o600)
        var st = stat()
        XCTAssertEqual(lstat(socket, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
        let d = try XCTUnwrap(UnivocalLocator.discovery(in: dir))
        XCTAssertEqual(d.socketPath, socket)
        XCTAssertEqual(d.pid, getpid())
        XCTAssertEqual(d.versions, [1])

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: UnivocalPaths.discoveryFileURL(in: dir).path), "removed on orderly shutdown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
    }

    /// C1: a `<ConnectDir>` too long for `sun_path` makes the server bind elsewhere;
    /// the client must use the socket advertised in connect.json.
    func testLongDirectoryFallsBackAndClientUsesDiscoveryPath() async throws {
        let long = dir.appendingPathComponent(String(repeating: "d", count: 90), isDirectory: true)
        XCTAssertFalse(UnivocalPaths.socketPathFits(UnivocalPaths.wellKnownSocketPath(in: long)))
        let server = try await startServer(in: long) { $0.consent = .autoGrant }
        let socket = await server.socketPath
        XCTAssertNotEqual(socket, UnivocalPaths.wellKnownSocketPath(in: long))
        XCTAssertTrue(UnivocalPaths.socketPathFits(socket))
        XCTAssertEqual(try mode((socket as NSString).deletingLastPathComponent), 0o700)
        XCTAssertEqual(UnivocalLocator.discovery(in: long)?.socketPath, socket)

        let client = makeClient(directory: long)
        let info = try await client.connect(launchIfNeeded: false)
        XCTAssertEqual(info.transport, .unixSocket)
    }

    // MARK: Availability (§4.1)

    func testAvailabilityUsesInjectedLocator() async throws {
        var c = UnivocalConfiguration(client: .init(id: "com.example.app", name: "App", version: "1"), environment: [:])
        c.connectDirectory = dir
        c.appLocator = { _ in nil }
        XCTAssertEqual(UnivocalLocator.availability(configuration: c), .notInstalled)
        let app = URL(fileURLWithPath: "/Applications/Univocal.app")
        c.appLocator = { _ in app }
        XCTAssertEqual(UnivocalLocator.availability(configuration: c), .installed(appURL: app, running: false))
        _ = try await startServer()
        XCTAssertEqual(UnivocalLocator.availability(configuration: c), .installed(appURL: app, running: true))
    }

    private func mode(_ path: String) throws -> mode_t {
        var st = stat()
        guard stat(path, &st) == 0 else { throw WaitTimeout(description: "stat \(path) failed") }
        return st.st_mode & 0o777
    }
}
