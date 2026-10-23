// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import XCTest
@testable import UnivocalClient
import UnivocalMock

/// SPEC §8 outbound coalescing / CONFORMANCE S31.
final class CoalescingTests: UnivocalTestCase {

    private func longText(words: Int) -> String {
        (0..<words).map { i in i % 10 == 9 ? "w\(i)." : "w\(i)" }.joined(separator: " ")
    }

    /// Polls a cheap condition on the mock (no fixed sleeps).
    private func eventually(timeout: Duration = .seconds(10), _ what: String,
                            _ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { throw WaitTimeout(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testSlowReaderStillGetsEveryStateAndEndedAndTheLatestWord() async throws {
        let mock = try await startServer {
            $0.wordsPerMinute = 1_200_000   // 20k words/s
            $0.slowConsumerThresholds = (coalesce: 2048, close: 64 * 1_048_576)
        }
        let r = try await rawWelcomed(mock)
        r.setReceiveBuffer(bytes: 2048)
        let text = longText(words: 10_000)
        try r.send(["type": "read", "id": 1, "sessionId": "slow", "text": .string(text)])
        // Do not read while the whole session plays out.
        try await eventually("the session to finish") { await mock.activeSessionId == nil }

        var all: [JSONObject] = []
        while true {
            guard let m = try await r.nextAsync(timeout: 5) else { break }
            all.append(m)
            if m.messageType == "ended" { break }
        }
        XCTAssertEqual(all.first?.messageType, "ok")
        let states = all.filter { $0.messageType == "state" }.compactMap { $0.string("state") }
        XCTAssertEqual(states, ["loading", "playing"], "state events are never dropped")
        XCTAssertEqual(all.last?.messageType, "ended")
        XCTAssertEqual(all.last?.string("reason"), "finished")

        let words = all.filter { $0.messageType == "word" }
        let expectedLast = MockTextAnalyzer.analyze(text).words.last!.range
        XCTAssertEqual(words.last.map { $0.int("start")!..<$0.int("end")! }, expectedLast, "the final word is the latest")
        XCTAssertLessThan(words.count, 10_000, "superseded words were dropped")
        let dropped = await mock.coalescedEventCount
        XCTAssertGreaterThan(dropped, 0)
        // Survivors stay in order.
        let starts = words.map { $0.int("start")! }
        XCTAssertEqual(starts, starts.sorted())
    }

    func testConsumerThatNeverReadsIsClosedWithSlowConsumer() async throws {
        let mock = try await startServer {
            $0.wordsPerMinute = 1_200_000
            $0.slowConsumerThresholds = (coalesce: Int.max, close: 128 * 1024)   // never coalesce → overflow
        }
        let r = try await rawWelcomed(mock)
        r.setReceiveBuffer(bytes: 2048)
        try r.send(["type": "read", "id": 1, "sessionId": "stuck", "text": .string(longText(words: 20_000))])
        try await eventually("slow-consumer close") { await mock.log.contains { $0.contains("slow consumer") } }
        let (_, closed) = await r.readUntilClosedAsync(timeout: 5)
        XCTAssertTrue(closed, "the server closes a consumer whose buffer passed the limit")
        try await eventually("the owner's session to end") { await mock.activeSessionId == nil }
    }
}
