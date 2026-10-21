// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum UnivocalAvailability: Sendable, Equatable {
    case notInstalled
    /// `running` == discovery file present and its pid alive.
    case installed(appURL: URL, running: Bool)
}

/// Installation, discovery and launch helpers (SPEC §4). All synchronous except `launch`.
public enum UnivocalLocator {
    public static let downloadURL = URL(string: "https://univocalapp.com")!

    public static func availability(configuration: UnivocalConfiguration) -> UnivocalAvailability {
        guard let url = configuration.appLocator(configuration.serverBundleId) else { return .notInstalled }
        return .installed(appURL: url, running: discovery(in: configuration.connectDirectory) != nil)
    }

    /// Parses `<dir>/connect.json`. `nil` if missing, unreadable, not Univocal Connect,
    /// or stale (its `pid` is not alive).
    public static func discovery(in connectDirectory: URL) -> UnivocalDiscovery? {
        let url = UnivocalPaths.discoveryFileURL(in: connectDirectory)
        guard let data = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode(UnivocalDiscovery.self, from: data),
              UnivocalPaths.processIsAlive(d.pid)
        else { return nil }
        return d
    }

    /// LaunchServices lookup; `nil` when no app with that bundle id is registered.
    public static func installedAppURL(bundleId: String) -> URL? {
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        #else
        return nil
        #endif
    }

    /// Launches the server in the background with `--connect` (SPEC §4.3).
    public static func launch(appURL: URL, bundleId: String) async throws {
        #if canImport(AppKit)
        let launched: Bool = await withCheckedContinuation { cont in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.arguments = ["--connect"]
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
                cont.resume(returning: app != nil && error == nil)
            }
        }
        if launched { return }
        #endif
        try launchWithOpen(bundleId: bundleId)
    }

    /// `open -g -b <bundleId> --args --connect`.
    static func launchWithOpen(bundleId: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", bundleId, "--args", "--connect"]
        do {
            try p.run()
        } catch {
            throw UnivocalError(code: .launchTimedOut, message: "Could not launch Univocal: \(error.localizedDescription)")
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UnivocalError(code: .launchTimedOut, message: "Could not launch Univocal (open exited \(p.terminationStatus)).")
        }
    }
}
