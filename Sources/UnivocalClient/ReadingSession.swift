// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import os

// MARK: - Requests and events

public struct ReadRequest: Sendable {
    public var text: String
    /// Default `UUID().uuidString`.
    public var sessionId: String
    /// BCP-47 hint.
    public var language: String?
    public var voice: String?
    public var rate: Double?
    /// UTF-16 offset into `text`, default 0. Univocal starts at the sentence containing it.
    public var startOffset: Int
    /// Default `true`: take over from whatever is playing. `false`: fail with `busy`.
    public var preempt: Bool
    /// Default `false`. Sent as `ui: "panel"` only if the server announced capability `panel`.
    public var showPanel: Bool
    /// `meta.title`, shown in Univocal's UI; never logged.
    public var title: String?

    public init(text: String) {
        self.text = text
        self.sessionId = UUID().uuidString
        self.language = nil
        self.voice = nil
        self.rate = nil
        self.startOffset = 0
        self.preempt = true
        self.showPanel = false
        self.title = nil
    }
}

public struct UnivocalVoice: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var lang: String?

    public init(id: String, name: String, lang: String? = nil) {
        self.id = id
        self.name = name
        self.lang = lang
    }
}

public enum PlaybackState: String, Sendable, Codable { case loading, playing, paused }
public enum EndReason: String, Sendable, Codable { case finished, stopped, preempted, error, revoked }

public enum ReadingEvent: Sendable, Equatable {
    case state(PlaybackState, detail: String?)
    /// UTF-16 half-open range into `ReadRequest.text`.
    case sentence(Range<Int>)
    /// UTF-16 half-open range. May repeat an identical range (one token spoken as several words).
    case word(Range<Int>)
    case progress(offset: Int)
    case rate(Double)
    /// Non-fatal session error; followed by `.ended(.error)` if the session died.
    case error(UnivocalError)
    /// Terminal; the stream finishes right after.
    case ended(EndReason, by: String?)
}

// MARK: - Session handle

/// Handle for one session. Owned by the client that created it; safe to use from any task.
public final class ReadingSession: Sendable {
    public let id: String
    public let textUTF16Count: Int
    /// Single-consumer, buffered from creation (nothing is lost between `read()` returning
    /// and iteration). Finishes after `.ended`. Consumers hop to the MainActor themselves.
    public let events: AsyncStream<ReadingEvent>

    let sink: SessionSink
    private let client: UnivocalClient

    init(id: String, textUTF16Count: Int, client: UnivocalClient) {
        self.id = id
        self.textUTF16Count = textUTF16Count
        self.client = client
        let (stream, cont) = AsyncStream<ReadingEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.sink = SessionSink(sessionId: id, textUTF16Count: textUTF16Count, continuation: cont)
    }

    /// Thread-safe snapshot: `true` once `.ended` has been delivered to the stream.
    public var isEnded: Bool { sink.isEnded }

    public func pause() async throws {
        try await client.control(self, type: "pause")
    }

    public func resume() async throws {
        try await client.control(self, type: "resume")
    }

    /// Resolves after the server's `ok`; `.ended(.stopped)` follows on the stream.
    public func stop() async throws {
        try await client.control(self, type: "stop")
    }

    public func seek(toUTF16Offset offset: Int) async throws {
        guard (0...textUTF16Count).contains(offset) else {
            throw UnivocalError(code: .invalidOffset, message: "Offset \(offset) is outside 0…\(textUTF16Count).", sessionId: id)
        }
        try await client.control(self, type: "seek", fields: ["offset": .int(offset)])
    }

    public func setRate(_ rate: Double) async throws {
        guard rate.isFinite, rate > 0 else {
            throw UnivocalError(code: .invalidArgument, message: "Rate must be a finite positive number.", sessionId: id)
        }
        try await client.control(self, type: "setRate", fields: ["rate": .double(rate)])
    }
}

/// Delivers events to one session's stream exactly until `.ended`.
final class SessionSink: Sendable {
    let sessionId: String
    let textUTF16Count: Int
    private let continuation: AsyncStream<ReadingEvent>.Continuation
    private let ended = OSAllocatedUnfairLock(initialState: false)

    init(sessionId: String, textUTF16Count: Int, continuation: AsyncStream<ReadingEvent>.Continuation) {
        self.sessionId = sessionId
        self.textUTF16Count = textUTF16Count
        self.continuation = continuation
    }

    var isEnded: Bool { ended.withLock { $0 } }

    /// Yields `event`; after `.ended` the stream finishes and further events are dropped.
    func yield(_ event: ReadingEvent) {
        let terminal: Bool
        if case .ended = event { terminal = true } else { terminal = false }
        let accepted: Bool = ended.withLock { isEnded in
            if isEnded { return false }
            if terminal { isEnded = true }
            return true
        }
        guard accepted else { return }
        continuation.yield(event)
        if terminal { continuation.finish() }
    }
}

// MARK: - Offsets helper

/// Converts between the wire's UTF-16 offsets and Swift string indices (SPEC §7).
public enum UTF16Offsets {
    /// `nil` if out of bounds; widens outward so a surrogate pair is never split.
    public static func range(_ r: Range<Int>, in text: String) -> Range<String.Index>? {
        let u = text.utf16
        guard r.lowerBound >= 0, r.upperBound <= u.count else { return nil }
        var lo = u.index(u.startIndex, offsetBy: r.lowerBound)
        var hi = u.index(lo, offsetBy: r.count)
        if lo != u.startIndex, lo != u.endIndex, UTF16.isTrailSurrogate(u[lo]) {
            lo = u.index(before: lo)
        }
        if hi != u.startIndex, hi != u.endIndex, UTF16.isTrailSurrogate(u[hi]) {
            hi = u.index(after: hi)
        }
        return lo..<hi
    }

    public static func nsRange(_ r: Range<Int>) -> NSRange {
        NSRange(location: r.lowerBound, length: r.count)
    }

    public static func utf16Count(_ s: String) -> Int {
        s.utf16.count
    }
}
