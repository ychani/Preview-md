// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalMock

/// SPEC §16.3 against real processes: this test runner and a spawned `/bin/sleep`.
final class ProcessAncestryTests: XCTestCase {

    private func spawnSleep() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        addTeardownBlock {
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
        }
        return p
    }

    func testChainOfThisProcessStartsWithItselfThenItsParent() {
        let chain = ProcessAncestry.chain(of: getpid())
        XCTAssertEqual(chain.first, getpid())
        if getppid() > 1 {
            XCTAssertEqual(chain.dropFirst().first, getppid())
        }
        XCTAssertFalse(chain.contains(1), "launchd ends the walk")
        XCTAssertFalse(chain.contains(0))
        XCTAssertLessThanOrEqual(chain.count, 17)
        XCTAssertEqual(Set(chain).count, chain.count)
    }

    func testSpawnedChildResolvesToTheTestRunnerByAncestry() throws {
        let child = try spawnSleep().processIdentifier
        let chain = ProcessAncestry.chain(of: child)
        XCTAssertEqual(Array(chain.prefix(2)), [child, getpid()])
        XCTAssertEqual(ProcessAncestry.chain(of: child, maxHops: 1), [child, getpid()])
        XCTAssertEqual(ProcessAncestry.chain(of: child, maxHops: 0), [child])
        XCTAssertTrue(ProcessAncestry.resolves(peerPid: child, appPid: getpid(), appBundleURL: nil))
        if getppid() > 1 {
            XCTAssertTrue(ProcessAncestry.resolves(peerPid: child, appPid: getppid(), appBundleURL: nil),
                          "two hops up still resolves")
        }
        XCTAssertFalse(ProcessAncestry.resolves(peerPid: getpid(), appPid: child, appBundleURL: nil),
                       "a parent does not resolve to its child")
    }

    func testBundleContainmentUsesTheExecutablePath() throws {
        let child = try spawnSleep().processIdentifier
        XCTAssertEqual(ProcessAncestry.executablePath(of: child), "/bin/sleep")
        XCTAssertTrue(ProcessAncestry.resolves(peerPid: child, appPid: nil, appBundleURL: URL(fileURLWithPath: "/bin")))
        XCTAssertTrue(ProcessAncestry.resolves(peerPid: child, appPid: nil, appBundleURL: URL(fileURLWithPath: "/bin/")))
        XCTAssertFalse(ProcessAncestry.resolves(peerPid: child, appPid: nil, appBundleURL: URL(fileURLWithPath: "/bi")),
                       "a path prefix must end at a component boundary")
        XCTAssertFalse(ProcessAncestry.resolves(peerPid: child, appPid: nil, appBundleURL: URL(fileURLWithPath: "/usr/sbin")))
        XCTAssertFalse(ProcessAncestry.resolves(peerPid: child, appPid: nil, appBundleURL: URL(fileURLWithPath: "/")))
    }

    func testUnrelatedProcessesDoNotResolve() {
        XCTAssertFalse(ProcessAncestry.resolves(peerPid: 1, appPid: getpid(), appBundleURL: nil))
        XCTAssertFalse(ProcessAncestry.resolves(peerPid: getpid(), appPid: 1, appBundleURL: nil), "launchd is never the app")
        XCTAssertFalse(ProcessAncestry.resolves(peerPid: getpid(), appPid: nil, appBundleURL: nil))
        XCTAssertFalse(ProcessAncestry.resolves(peerPid: 0, appPid: 0, appBundleURL: nil))
        XCTAssertEqual(ProcessAncestry.chain(of: 0), [])
        XCTAssertEqual(ProcessAncestry.chain(of: -5), [])
        XCTAssertNil(ProcessAncestry.executablePath(of: 0))
    }

    func testOnlyPublicAPIsAreUsed() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UnivocalMock/ProcessAncestry.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(code.contains("responsibility_get_pid_responsible_for_pid("), "private SPI is forbidden (SPEC §16.3)")
        XCTAssertFalse(code.contains("dlsym"))
        XCTAssertTrue(code.contains("PROC_PIDTBSDINFO"))
        XCTAssertTrue(code.contains("proc_pidpath"))
    }
}
