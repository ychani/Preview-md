// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient
import UnivocalMock

/// The live-server probe (`univocal-mock check`) run against the mock itself:
/// every non-manual item it can evaluate must PASS.
final class MockConformanceTests: UnivocalTestCase {

    func testProbePassesAgainstTheMock() async throws {
        let mock = try await startServer {
            $0.wordsPerMinute = 6000
            $0.loadingDelay = .milliseconds(20)
        }
        var options = ConformanceOptions(directory: dir)
        options.autograntExpected = true
        options.eventTimeout = 5
        // S37/S43: the probe runs in this process, so it resolves to a frontmost "app" with our pid.
        options.hotkeyPressTimeout = 5
        options.hotkeyTrigger = {
            Task {
                await mock.setFrontmost(MockFrontmost(pid: getpid(), bundleId: "dev.univocal.conformance-probe"))
                _ = await mock.simulateHotkey()
            }
        }
        let results = await MockConformance.run(options)
        XCTAssertEqual(results.map(\.item), MockConformance.items)

        let failures = results.filter { $0.status == .fail }
        XCTAssertTrue(failures.isEmpty, MockConformance.format(failures))

        // Covered by dedicated tests / no ws in the mock / need scripted timing or several apps.
        let notProbed: Set<String> = ["S15", "S31", "S35", "S42", "S44", "S48"]
        let expectedPass = Set(MockConformance.items).subtracting(MockConformance.manualItems).subtracting(notProbed)
        let passed = Set(results.filter { $0.status == .pass }.map(\.item))
        XCTAssertEqual(passed, expectedPass, MockConformance.format(results))

        let log = await mock.log.joined(separator: "\n")
        XCTAssertFalse(log.contains("Revenue"), "the probe's fixture text never reaches the log")
        XCTAssertFalse(log.contains("brighter"))
    }

    func testProbeSkipsHotkeyItemsAgainstADraft1Server() async throws {
        _ = try await startServer {
            $0.wordsPerMinute = 6000
            $0.hotkeyRouting = false
        }
        var options = ConformanceOptions(directory: dir)
        options.autograntExpected = true
        options.eventTimeout = 5
        let results = await MockConformance.run(options)
        for item in ["S37", "S43", "S45", "S50"] {
            XCTAssertEqual(results.first { $0.item == item }?.status, .skip, item)
        }
        XCTAssertTrue(results.filter { $0.status == .fail }.isEmpty, MockConformance.format(results))
    }

    func testProbeReportsFailuresAgainstAMisbehavingServer() async throws {
        // A server whose welcome advertises a too-small frame limit fails S33.
        _ = try await startServer {
            $0.maxFrameBytes = 4096
            $0.wordsPerMinute = 6000
        }
        var options = ConformanceOptions(directory: dir)
        options.autograntExpected = true
        options.eventTimeout = 2
        let results = await MockConformance.run(options)
        XCTAssertEqual(results.first { $0.item == "S33" }?.status, .fail)
        XCTAssertEqual(results.first { $0.item == "S4" }?.status, .fail, "a 1 MiB frame must be accepted")
    }

    func testProbeWithoutServerFailsDiscovery() async throws {
        let results = await MockConformance.run(ConformanceOptions(directory: dir))
        XCTAssertEqual(results.first { $0.item == "S8" }?.status, .fail)
        XCTAssertEqual(results.first { $0.item == "S1" }?.status, .fail)
    }
}
