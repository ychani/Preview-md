import MdReaderCore
import UnivocalClient
import WebKit
import XCTest
@testable import MdReader

// MARK: - Fakes

/// A session whose events the test feeds, recording the controls it gets.
private final class FakeSession: ReadAloudSession, @unchecked Sendable {
    let id = UUID().uuidString
    let events: AsyncStream<ReadingEvent>
    private let continuation: AsyncStream<ReadingEvent>.Continuation
    private let lock = NSLock()
    private var _calls: [String] = []

    init() {
        var c: AsyncStream<ReadingEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
    }

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func record(_ call: String) { lock.lock(); _calls.append(call); lock.unlock() }

    func send(_ events: ReadingEvent...) {
        for event in events { continuation.yield(event) }
    }

    func pause() async throws { record("pause") }
    func resume() async throws { record("resume") }
    func stop() async throws { record("stop") }
    func seek(toUTF16Offset offset: Int) async throws { record("seek:\(offset)") }
}

private final class FakeBackend: ReadAloudBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ReadRequest] = []
    private var _sessions: [FakeSession] = []
    private var held: CheckedContinuation<Void, Never>?
    private var stateContinuations: [AsyncStream<UnivocalConnectionState>.Continuation] = []

    var installed = true
    /// Thrown by the next `startReading`.
    var error: Error?
    /// `startReading` waits for `release()`.
    var hold = false

    var requests: [ReadRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var sessions: [FakeSession] { lock.lock(); defer { lock.unlock() }; return _sessions }

    func availability() -> UnivocalAvailability {
        installed ? .installed(appURL: URL(fileURLWithPath: "/Applications/Univocal.app"), running: false)
                  : .notInstalled
    }

    func connectionStates() -> AsyncStream<UnivocalConnectionState> {
        AsyncStream { continuation in
            lock.lock()
            stateContinuations.append(continuation)
            lock.unlock()
            continuation.yield(.disconnected)
        }
    }

    func sendState(_ state: UnivocalConnectionState) {
        lock.lock()
        let all = stateContinuations
        lock.unlock()
        for c in all { c.yield(state) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func startReading(_ request: ReadRequest) async throws -> any ReadAloudSession {
        let shouldHold = locked { () -> Bool in
            _requests.append(request)
            return hold
        }
        if shouldHold {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                locked { held = c }
            }
        }
        if let error {
            self.error = nil
            throw error
        }
        let session = FakeSession()
        locked { _sessions.append(session) }
        return session
    }

    func release() {
        lock.lock()
        let c = held
        held = nil
        hold = false
        lock.unlock()
        c?.resume()
    }

    var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return held != nil }
}

@MainActor
private final class FakeBridge: ReadAloudWebBridging {
    enum Call: Equatable {
        case requestText(Int)
        case activate(Int)
        case reattach(String, Range<Int>?, Range<Int>?)
        case apply(Range<Int>?, Range<Int>?)
        case deactivate
    }

    var webView: WKWebView?
    var calls: [Call] = []

    func requestText(request: Int) { calls.append(.requestText(request)) }
    func activate(generation: Int) { calls.append(.activate(generation)) }
    func reattach(text: String, word: Range<Int>?, sentence: Range<Int>?) {
        calls.append(.reattach(text, word, sentence))
    }
    func apply(word: Range<Int>?, sentence: Range<Int>?) { calls.append(.apply(word, sentence)) }
    func deactivate() { calls.append(.deactivate) }
}

// MARK: - Tests

@MainActor
final class ReadAloudControllerTests: XCTestCase {
    private var backend: FakeBackend!
    private var bridge: FakeBridge!
    private var opened: [URL] = []
    private var controller: ReadAloudController!
    private var page: WKWebView!

    override func setUp() async throws {
        backend = FakeBackend()
        bridge = FakeBridge()
        opened = []
        page = WKWebView(frame: .zero)
        controller = ReadAloudController(backend: backend, bridge: bridge, openURL: { [weak self] in
            self?.opened.append($0)
        })
        controller.documentTitle = { "Notes.md" }
        controller.handle(.ready(highlightMode: "css-highlight"), from: page)
    }

    override func tearDown() async throws {
        backend?.release()
        controller = nil
        page = nil
    }

    /// Polls (yielding to the tasks under test) until `condition` holds.
    private func eventually(
        _ message: @autoclosure () -> String = "condition",
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(message())", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private nonisolated static let text = "Hello world. Second one."

    /// Play → page text → a playing session.
    @discardableResult
    private func startPlaying(text: String = text, generation: Int = 1) async -> FakeSession {
        controller.toggle()
        XCTAssertEqual(controller.status, .starting(nil))
        guard case .requestText(let request)? = bridge.calls.last else {
            XCTFail("no requestText")
            return FakeSession()
        }
        controller.handle(.text(text, generation: generation, request: request), from: page)
        let count = backend.sessions.count
        await eventually("session") { backend.sessions.count == count + 1 }
        let session = backend.sessions[count]
        await eventually("activate") { bridge.calls.contains(.activate(generation)) }
        session.send(.state(.loading, detail: nil), .state(.playing, detail: nil))
        await eventually("playing") { controller.status == .playing }
        return session
    }

    func testPlayHighlightsWordsInOrderThenFinishes() async {
        let session = await startPlaying()
        let request = backend.requests[0]
        XCTAssertEqual(request.text, Self.text)
        XCTAssertEqual(request.startOffset, 0)
        XCTAssertEqual(request.title, "Notes.md")
        XCTAssertTrue(request.preempt)

        session.send(.sentence(0..<12), .word(0..<5), .word(6..<11), .word(6..<11))
        await eventually { bridge.calls.filter { if case .apply = $0 { return true } else { return false } }.count == 4 }
        XCTAssertEqual(Array(bridge.calls.suffix(4)), [
            .apply(nil, 0..<12), .apply(0..<5, 0..<12), .apply(6..<11, 0..<12), .apply(6..<11, 0..<12),
        ])
        XCTAssertEqual(controller.currentWord, 6..<11)

        session.send(.ended(.finished, by: nil))
        await eventually { controller.status == .idle }
        XCTAssertEqual(bridge.calls.last, .deactivate)
        XCTAssertNil(controller.currentWord)
    }

    func testLoadingDetailShowsWhileStarting() async {
        let session = await startPlaying()
        session.send(.state(.loading, detail: "Waiting for text…"))
        await eventually { controller.status == .starting("Waiting for text…") }
    }

    func testPauseResumeStop() async {
        let session = await startPlaying()
        controller.toggle()
        await eventually { session.calls == ["pause"] }
        session.send(.state(.paused, detail: nil))
        await eventually { controller.status == .paused }
        XCTAssertEqual(controller.toggleTitle, "Resume Reading")
        controller.toggle()
        await eventually { session.calls == ["pause", "resume"] }

        controller.stop()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(bridge.calls.last, .deactivate)
        await eventually { session.calls.last == "stop" }
        // Late events from the stopped session are ignored.
        session.send(.word(0..<5))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(bridge.calls.last, .deactivate)
    }

    func testPreemptionEndsSilently() async {
        let session = await startPlaying()
        session.send(.ended(.preempted, by: "Univocal"))
        await eventually { controller.status == .idle }
    }

    func testSessionErrorIsReported() async {
        let session = await startPlaying()
        session.send(.error(UnivocalError(code: .engineError, message: "boom")), .ended(.error, by: nil))
        await eventually { controller.status == .failed("Univocal couldn't read this document") }
        XCTAssertEqual(controller.menuTitle, "Read Aloud — Univocal couldn't read this document")
    }

    func testRevokedMidSessionAsksAgainLater() async {
        let session = await startPlaying()
        session.send(.ended(.revoked, by: nil))
        await eventually {
            if case .unauthorized = controller.status { return true } else { return false }
        }
    }

    func testDocumentChangeStops() async {
        let session = await startPlaying()
        controller.documentDidChange()
        XCTAssertEqual(controller.status, .idle)
        await eventually { session.calls.contains("stop") }
    }

    func testClickToSeekGoesToTheSession() async {
        let session = await startPlaying()
        controller.handle(.seek(offset: 13), from: page)
        await eventually { session.calls == ["seek:13"] }
    }

    // MARK: Text changes

    func testTextChangeRestartsAtTheRemappedOffset() async {
        let old = await startPlaying()
        let changed = "Hello brave world. Second one."
        controller.handle(.textChanged(changed, startOffset: 19, generation: 2), from: page)
        await eventually { backend.requests.count == 2 }
        XCTAssertEqual(old.calls, ["stop"], "the old session stops before the new read")
        XCTAssertEqual(backend.requests[1].text, changed)
        XCTAssertEqual(backend.requests[1].startOffset, 19)
        await eventually { bridge.calls.last == .activate(2) }
    }

    func testTextChangeWhilePausedRestartsOnResume() async {
        let session = await startPlaying()
        controller.toggle()
        session.send(.state(.paused, detail: nil))
        await eventually { controller.status == .paused }
        controller.handle(.textChanged("Changed.", startOffset: 0, generation: 2), from: page)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(backend.requests.count, 1, "no restart while paused")
        controller.toggle()
        await eventually { backend.requests.count == 2 }
        XCTAssertEqual(backend.requests[1].text, "Changed.")
        XCTAssertFalse(session.calls.contains("resume"))
    }

    func testNewPageReattachesTheRunningSession() async {
        let session = await startPlaying()
        session.send(.sentence(0..<12), .word(6..<11))
        await eventually { controller.currentWord == 6..<11 }
        let newPage = WKWebView(frame: .zero)
        controller.handle(.ready(highlightMode: "mark"), from: newPage)
        XCTAssertTrue(bridge.webView === newPage)
        XCTAssertEqual(bridge.calls.last, .reattach(Self.text, 6..<11, 0..<12))
        XCTAssertEqual(controller.highlightMode, "mark")
    }

    // MARK: Starting, consent, availability

    func testNotInstalledOffersDownload() {
        backend.installed = false
        controller.refreshAvailability()
        XCTAssertEqual(controller.status, .unavailable)
        XCTAssertFalse(controller.canToggle(documentReady: true))
        controller.toggle()
        XCTAssertEqual(opened, [UnivocalLocator.downloadURL])
        XCTAssertFalse(bridge.calls.contains { if case .requestText = $0 { return true } else { return false } })

        // Installed meanwhile: the next click reads.
        backend.installed = true
        controller.toggle()
        XCTAssertEqual(controller.status, .starting(nil))
    }

    func testAwaitingConsentThenDenied() async {
        backend.hold = true
        backend.error = UnivocalError(code: .consentDenied, reason: "user")
        controller.toggle()
        guard case .requestText(let request)? = bridge.calls.last else { return XCTFail("no requestText") }
        controller.handle(.text(Self.text, generation: 1, request: request), from: page)
        await eventually { backend.isHolding }
        backend.sendState(.launching)
        await eventually { controller.status == .starting("Starting Univocal…") }
        backend.sendState(.awaitingConsent)
        await eventually { controller.status == .awaitingConsent }
        XCTAssertEqual(controller.helpText, "Waiting for approval in Univocal…")
        XCTAssertFalse(controller.canToggle(documentReady: true))
        backend.release()
        await eventually { controller.status == .unauthorized(ReadAloudController.consentMessage(reason: "user")) }

        // Retry asks again.
        controller.toggle()
        XCTAssertEqual(controller.status, .starting(nil))
        XCTAssertEqual(bridge.calls.filter { if case .requestText = $0 { return true } else { return false } }.count, 2)
    }

    func testLaunchFailureShowsMessage() async {
        backend.error = UnivocalError(code: .launchTimedOut)
        controller.toggle()
        guard case .requestText(let request)? = bridge.calls.last else { return XCTFail("no requestText") }
        controller.handle(.text(Self.text, generation: 1, request: request), from: page)
        await eventually { controller.status == .failed("Univocal didn't start") }
    }

    func testStopWhileStartingStopsTheLateSession() async {
        backend.hold = true
        controller.toggle()
        guard case .requestText(let request)? = bridge.calls.last else { return XCTFail("no requestText") }
        controller.handle(.text(Self.text, generation: 1, request: request), from: page)
        await eventually { backend.isHolding }
        controller.stop()
        XCTAssertEqual(controller.status, .idle)
        backend.release()
        await eventually { backend.sessions.first?.calls == ["stop"] }
        XCTAssertEqual(controller.status, .idle)
    }

    func testPageWithoutTextFails() {
        controller.toggle()
        guard case .requestText(let request)? = bridge.calls.last else { return XCTFail("no requestText") }
        controller.handle(.error(code: "noContent", request: request), from: page)
        XCTAssertEqual(controller.status, .failed("There is no text to read in this document"))
        XCTAssertTrue(backend.requests.isEmpty)
        // A stale reply is ignored.
        controller.handle(.text(Self.text, generation: 1, request: request), from: page)
        XCTAssertTrue(backend.requests.isEmpty)
    }

    func testNeedsAPreview() {
        let lonely = ReadAloudController(backend: backend, bridge: FakeBridge(), openURL: { _ in })
        lonely.toggle()
        XCTAssertEqual(lonely.status, .failed("Show the preview to read aloud"))
    }
}
