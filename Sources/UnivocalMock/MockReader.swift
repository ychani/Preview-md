// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
import UnivocalClient

// MARK: - Text analysis (the offset reference)

/// Sentence and word segmentation over the exact UTF-16 text a client sent
/// (SPEC §7). This is the mock's *reference* for offsets: `NSString` and
/// `NSRegularExpression` are UTF-16 native, so emoji, CJK, CRLF and combining
/// sequences produce the ranges a correct server would.
///
/// * Sentences end after `[.!?]+` followed by whitespace, and at every `\n`
///   (so `\n\n` is always a boundary). Ranges are trimmed of whitespace.
/// * Words are runs of non-whitespace with leading/trailing punctuation
///   trimmed, widened to whole composed character sequences (never splitting a
///   surrogate pair).
/// * A currency token such as `$5B` is "spoken" as three words with the same
///   source range (like "five billion dollars"), exercising identical
///   consecutive `word` ranges.
public enum MockTextAnalyzer {
    public struct Word: Sendable, Equatable {
        public var range: Range<Int>
        /// Index into `Analysis.sentences`.
        public var sentence: Int
        /// How many `word` events this token produces (3 for `$5B`-style tokens).
        public var repeats: Int
    }

    public struct Analysis: Sendable, Equatable {
        public var sentences: [Range<Int>]
        public var words: [Word]
    }

    public static func analyze(_ text: String) -> Analysis {
        let s = text as NSString
        let r = analyze(s, from: 0, to: s.length, sentenceBase: 0)
        return Analysis(sentences: r.sentences, words: r.words)
    }

    private static let boundaryRegex = try! NSRegularExpression(pattern: "[.!?]+(?=\\s)|\\n")
    private static let tokenRegex = try! NSRegularExpression(pattern: "\\S+")
    private static let trimmable: Set<unichar> = Set(".,;:!?\"'()[]{}“”‘’«»…*_`~<>".utf16)

    /// End offset of the last sentence boundary inside `[from, to)`, if any.
    static func lastBoundaryEnd(_ s: NSString, from: Int, to: Int) -> Int? {
        guard to > from else { return nil }
        var last: Int?
        boundaryRegex.enumerateMatches(in: s as String, range: NSRange(location: from, length: to - from)) { m, _, _ in
            if let m { last = m.range.location + m.range.length }
        }
        return last
    }

    /// Analyses `[from, to)`; sentence indices start at `sentenceBase`. `from` must
    /// be a sentence start (0 or just after a boundary).
    static func analyze(_ s: NSString, from: Int, to: Int, sentenceBase: Int) -> (sentences: [Range<Int>], words: [Word]) {
        guard to > from else { return ([], []) }
        let region = NSRange(location: from, length: to - from)
        var cuts: [Int] = []
        boundaryRegex.enumerateMatches(in: s as String, range: region) { m, _, _ in
            if let m { cuts.append(m.range.location + m.range.length) }
        }
        if cuts.last != to { cuts.append(to) }

        var sentences: [Range<Int>] = []
        var start = from
        for cut in cuts {
            var a = start, b = cut
            while a < b, isSpace(s.character(at: a)) { a += 1 }
            while b > a, isSpace(s.character(at: b - 1)) { b -= 1 }
            if a < b { sentences.append(a..<b) }
            start = cut
        }

        var words: [Word] = []
        var si = 0
        tokenRegex.enumerateMatches(in: s as String, range: region) { m, _, _ in
            guard let m else { return }
            var a = m.range.location, b = m.range.location + m.range.length
            while a < b, trimmable.contains(s.character(at: a)) { a += 1 }
            while b > a, trimmable.contains(s.character(at: b - 1)) { b -= 1 }
            guard a < b else { return }
            // Never split a surrogate pair or a composed sequence; stay inside the token.
            let widened = s.rangeOfComposedCharacterSequences(for: NSRange(location: a, length: b - a))
            a = max(widened.location, m.range.location)
            b = min(widened.location + widened.length, m.range.location + m.range.length)
            while si < sentences.count, sentences[si].upperBound <= a { si += 1 }
            guard si < sentences.count else { return }
            let repeats = s.character(at: a) == 0x24 /* $ */ && b - a > 1 && isDigit(s.character(at: a + 1)) ? 3 : 1
            words.append(Word(range: a..<b, sentence: sentenceBase + si, repeats: repeats))
        }
        return (sentences, words)
    }

    private static func isSpace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
}

// MARK: - One fake reading session

/// The fake playback clock for one session. Confined to the engine's queue.
final class MockReading: @unchecked Sendable {
    struct Unit {
        var range: Range<Int>
        var sentence: Int
    }

    enum Phase { case loading, playing, waiting }

    let sessionId: String
    let ownerId: Int
    unowned let engine: MockEngine

    let text = NSMutableString()
    private(set) var utf8Bytes = 0
    private(set) var morePending = false
    private(set) var sentences: [Range<Int>] = []
    private var units: [Unit] = []
    private var analyzedUpTo = 0
    private var nextUnit = 0
    /// Lazy skip for `startOffset`/`seek` targets beyond the analysed text.
    private var skip: (offset: Int, bySentence: Bool)?
    private var currentSentence: Int?
    private(set) var phase: Phase = .loading
    private(set) var paused = false
    private(set) var ended = false
    private(set) var rate: Double
    private var timer: DispatchSourceTimer?
    private var lastProgress = DispatchTime.now()

    private(set) var wordEvents = 0
    private(set) var sentenceEvents = 0

    init(engine: MockEngine, sessionId: String, ownerId: Int, rate: Double) {
        self.engine = engine
        self.sessionId = sessionId
        self.ownerId = ownerId
        self.rate = rate
    }

    var utf16Length: Int { text.length }

    // MARK: Text

    func append(_ chunk: String, more: Bool) {
        text.append(chunk)
        utf8Bytes += chunk.utf8.count
        morePending = more
        let length = text.length
        // While more text is pending, hold the trailing partial sentence (SPEC §8).
        let limit = more ? (MockTextAnalyzer.lastBoundaryEnd(text, from: analyzedUpTo, to: length) ?? analyzedUpTo) : length
        if limit > analyzedUpTo {
            let r = MockTextAnalyzer.analyze(text, from: analyzedUpTo, to: limit, sentenceBase: sentences.count)
            sentences.append(contentsOf: r.sentences)
            for w in r.words {
                for _ in 0..<w.repeats { units.append(Unit(range: w.range, sentence: w.sentence)) }
            }
            analyzedUpTo = limit
        }
        applySkip()
        if phase == .waiting, nextUnit < units.count || !morePending {
            phase = .playing
            if !paused {
                engine.sessionEvent(self, ["type": "state", "state": "playing"])
                startTimer()
            }
        }
    }

    // MARK: Lifecycle

    func start(startOffset: Int) {
        if startOffset > 0 {
            skip = (startOffset, true)
            applySkip()
        }
        engine.sessionEvent(self, ["type": "state", "state": "loading", "detail": "Starting speech engine…"])
        let delay = engine.behaviour.loadingDelay.timeInterval
        engine.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.loadingFinished()
        }
    }

    private func loadingFinished() {
        guard !ended, phase == .loading else { return }
        phase = .playing
        lastProgress = .now()
        guard !paused else { return }
        engine.sessionEvent(self, ["type": "state", "state": "playing"])
        startTimer()
    }

    func pause() {
        guard !paused, !ended else { return }
        paused = true
        stopTimer()
        engine.sessionEvent(self, ["type": "state", "state": "paused"])
    }

    func resume() {
        guard paused, !ended else { return }
        paused = false
        switch phase {
        case .loading:
            engine.sessionEvent(self, ["type": "state", "state": "loading", "detail": "Starting speech engine…"])
        case .playing:
            engine.sessionEvent(self, ["type": "state", "state": "playing"])
            startTimer()
        case .waiting:
            engine.sessionEvent(self, ["type": "state", "state": "loading", "detail": "Waiting for text…"])
        }
    }

    func seek(to offset: Int) {
        skip = (offset, false)
        nextUnit = 0
        currentSentence = nil
        applySkip()
    }

    func setRate(_ r: Double) {
        rate = r
        engine.sessionEvent(self, ["type": "rate", "rate": .double(r)])
        if timer != nil {
            stopTimer()
            startTimer()
        }
    }

    /// Ends the session and notifies the owner (unless `silently`).
    func finish(_ reason: String, by: String? = nil, silently: Bool = false) {
        guard !ended else { return }
        ended = true
        stopTimer()
        engine.readingEnded(self, reason: reason, by: by, silently: silently)
    }

    // MARK: Clock

    /// Manual clock (`wordsPerMinute <= 0`): speak up to `count` word units.
    func advance(_ count: Int) {
        var n = count
        while n > 0, !ended, !paused, phase == .playing {
            tick()
            n -= 1
        }
    }

    private var manual: Bool { engine.behaviour.wordsPerMinute <= 0 }

    private func startTimer() {
        guard !manual, timer == nil, !ended else { return }
        let wordSeconds = 60.0 / (engine.behaviour.wordsPerMinute * rate)
        let interval = max(wordSeconds, 0.001)
        let perTick = max(1, Int((interval / wordSeconds).rounded(.down)))
        let t = DispatchSource.makeTimerSource(queue: engine.queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .microseconds(200))
        t.setEventHandler { [weak self] in
            for _ in 0..<perTick {
                guard let self, self.timer != nil else { return }
                self.tick()
            }
        }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard !ended, !paused, phase == .playing else { return }
        applySkip()
        guard nextUnit < units.count else {
            if morePending {
                phase = .waiting
                stopTimer()
                engine.sessionEvent(self, ["type": "state", "state": "loading", "detail": "Waiting for text…"])
            } else {
                finish("finished")
            }
            return
        }
        let u = units[nextUnit]
        nextUnit += 1
        if currentSentence != u.sentence {
            currentSentence = u.sentence
            let s = sentences[u.sentence]
            sentenceEvents += 1
            engine.sessionEvent(self, ["type": "sentence", "start": .int(s.lowerBound), "end": .int(s.upperBound)])
        }
        wordEvents += 1
        engine.sessionEvent(self, ["type": "word", "start": .int(u.range.lowerBound), "end": .int(u.range.upperBound)])
        let now = DispatchTime.now()
        if now.uptimeNanoseconds - lastProgress.uptimeNanoseconds >= 1_000_000_000 {
            lastProgress = now
            engine.sessionEvent(self, ["type": "progress", "offset": .int(u.range.upperBound)])
        }
    }

    /// Moves `nextUnit` to the first unit at/after a pending skip target.
    private func applySkip() {
        guard let target = skip else { return }
        let pass: (Unit) -> Bool = { u in
            target.bySentence ? self.sentences[u.sentence].upperBound > target.offset : u.range.upperBound > target.offset
        }
        // Units are sorted by range, and sentence upper bounds are monotonic, so bisect.
        var lo = nextUnit, hi = units.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pass(units[mid]) { hi = mid } else { lo = mid + 1 }
        }
        nextUnit = lo
        if lo < units.count || !morePending { skip = nil }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
