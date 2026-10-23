import MdReaderCore
import UnivocalClient
import WebKit
import XCTest
@testable import MdReader

// MARK: - Fakes

/// A session whose events the test feeds, recording the calls it gets
/// (stop and seek only: Univocal's pill pauses and resumes).
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

    func stop() async throws { record("stop") }
    func seek(toUTF16Offset offset: Int) async throws { record("seek:\(offset)") }
}

private final class FakeBackend: ReadAloudBackend, @unchecked Sendable {
    struct Decline: Equatable {
        let id: String
        let reason: UnivocalDeclineReason
        let detail: String?
    }

    private let lock = NSLock()
    private var _requests: [ReadRequest] = []
    /// The hotkey request each entry of `requests` answered (nil: in-app).
    private var _answering: [String?] = []
    private var _sessions: [FakeSession] = []
    private var _log: [String] = []
    private var _declines: [Decline] = []
    private var held: CheckedContinuation<Void, Never>?
    private var stateContinuations: [AsyncStream<UnivocalConnectionState>.Continuation] = []
    private var requestContinuations: [AsyncStream<UnivocalReadRequest>.Continuation] = []
    private var appearanceContinuations: [AsyncStream<UnivocalDiscovery>.Continuation] = []

    var installed = true
    /// Thrown by the next `startReading`.
    var error: Error?
    /// `startReading` waits for `release()`.
    var hold = false

    var requests: [ReadRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var answering: [String?] { lock.lock(); defer { lock.unlock() }; return _answering }
    var sessions: [FakeSession] { lock.lock(); defer { lock.unlock() }; return _sessions }
    /// Hotkey calls in order: "accept:<id>", "read:<id>", "decline:<id>",
    /// "connectIfAuthorized", "wake:<id>".
    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    var declines: [Decline] { lock.lock(); defer { lock.unlock() }; return _declines }

    func sendRequest(_ request: UnivocalReadRequest) {
        let all = locked { requestContinuations }
        for c in all { c.yield(request) }
    }

    func serverAppeared() {
        let all = locked { appearanceContinuations }
        for c in all {
            c.yield(UnivocalDiscovery(socketPath: "/tmp/x.sock", pid: 1, serverName: "Univocal",
                                      serverVersion: "1", serverBundleId: "com.univocal.app"))
        }
    }

    func readRequests() -> AsyncStream<UnivocalReadRequest> {
        AsyncStream { c in locked { requestContinuations.append(c) } }
    }

    func accept(_ request: UnivocalReadRequest) async throws {
        locked { _log.append("accept:\(request.id)") }
    }

    func decline(_ request: UnivocalReadRequest, reason: UnivocalDeclineReason, detail: String?) async throws {
        locked {
            _log.append("decline:\(request.id)")
            _declines.append(Decline(id: request.id, reason: reason, detail: detail))
        }
    }

    func startReading(_ request: ReadRequest, answering hotkey: UnivocalReadRequest) async throws
        -> any ReadAloudSession {
        locked { _log.append("read:\(hotkey.id)") }
        return try await start(request, answering: hotkey.id)
    }

    func connectIfAuthorized() async throws -> Bool {
        locked { _log.append("connectIfAuthorized") }
        return true
    }

    func connectForWake(requestId: String) async throws {
        locked { _log.append("wake:\(requestId)") }
    }

    func serverAppearances() -> AsyncStream<UnivocalDiscovery> {
        AsyncStream { c in locked { appearanceContinuations.append(c) } }
    }

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
        try await start(request, answering: nil)
    }

    private func start(_ request: ReadRequest, answering: String?) async throws -> any ReadAloudSession {
        let shouldHold = locked { () -> Bool in
            _requests.append(request)
            _answering.append(answering)
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
    /// The `prefer` of each `requestText`, by request number.
    var prefers: [Int: ReadAloudBridge.StartPreference] = [:]

    func requestText(request: Int, prefer: ReadAloudBridge.StartPreference?) {
        calls.append(.requestText(request))
        prefers[request] = prefer
    }
    func activate(generation: Int) { calls.append(.activate(generation)) }
    func reattach(text: String, word: Range<Int>?, sentence: Range<Int>?) {
        calls.append(.reattach(text, word, sentence))
    }
    func apply(word: Range<Int>?, sentence: Range<Int>?) { calls.append(.apply(word, sentence)) }
    func deactivate() { calls.append(.deactivate) }
}

@MainActor
private final class FakeEditor: ReadAloudEditorSurface {
    struct Paint: Equatable {
        let word: Range<Int>?
        let sentence: Range<Int>?
    }

    let text: String
    var selectedRange: NSRange
    var visibleStart = 0
    var isFocused = true
    var onInvalidate: (() -> Void)?
    var paints: [Paint] = []
    var clears = 0

    init(text: String, selection: NSRange = NSRange(location: 0, length: 0)) {
        self.text = text
        selectedRange = selection
    }

    func visibleStartOffset() -> Int { visibleStart }
    func paint(word: Range<Int>?, sentence: Range<Int>?) { paints.append(Paint(word: word, sentence: sentence)) }
    func clear() { clears += 1 }
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
        controller.readAloud()
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

    func testStopEndsTheSessionAndIgnoresLateEvents() async {
        let session = await startPlaying()
        controller.stop()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(bridge.calls.last, .deactivate)
        await eventually { session.calls.last == "stop" }
        // Late events from the stopped session are ignored.
        session.send(.word(0..<5))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(bridge.calls.last, .deactivate)
    }

    /// Univocal's pill is the only transport control: PreviewMD's Read
    /// Aloud command never pauses, resumes or stops a running session.
    func testReadAloudCommandDoesNothingWhileReading() async {
        let session = await startPlaying()
        controller.readAloud()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.status, .playing)
        session.send(.state(.paused, detail: nil))
        await eventually { controller.status == .paused }
        controller.readAloud()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.status, .paused)
        XCTAssertTrue(session.calls.isEmpty, "no stop or seek from PreviewMD: \(session.calls)")
        XCTAssertEqual(backend.requests.count, 1, "no new read either")
    }

    /// While reading, the toolbar and menu only say where the controls are.
    func testWhileReadingTheCommandIsDisabledAndPointsToUnivocal() async {
        XCTAssertEqual(controller.menuTitle, "Read Aloud")
        XCTAssertTrue(controller.canStart(documentReady: true))
        XCTAssertFalse(controller.canStart(documentReady: false))
        let session = await startPlaying()
        XCTAssertTrue(controller.status.isReading)
        XCTAssertFalse(controller.canStart(documentReady: true))
        XCTAssertEqual(controller.menuTitle, "Reading Aloud — Controls in Univocal")
        XCTAssertEqual(controller.helpText, "Reading aloud — pause, skip or stop in Univocal's controls")
        session.send(.state(.paused, detail: nil))
        await eventually { controller.status == .paused }
        XCTAssertTrue(controller.status.isReading)
        XCTAssertFalse(controller.canStart(documentReady: true))
        XCTAssertEqual(controller.menuTitle, "Reading Aloud — Controls in Univocal")
        XCTAssertEqual(controller.helpText, "Reading paused — resume or stop in Univocal's controls")
        session.send(.ended(.stopped, by: nil))
        await eventually { controller.status == .idle }
        XCTAssertFalse(controller.status.isReading)
        XCTAssertTrue(controller.canStart(documentReady: true))
        XCTAssertEqual(controller.helpText, "Read Aloud")
    }

    /// The pill's pause/resume/stop arrive as ordinary session events.
    func testUnivocalsControlsDriveTheStatus() async {
        let session = await startPlaying()
        session.send(.state(.paused, detail: nil))
        await eventually { controller.status == .paused }
        session.send(.state(.playing, detail: nil), .sentence(13..<24), .word(13..<19))
        await eventually { controller.status == .playing && controller.currentWord == 13..<19 }
        session.send(.ended(.stopped, by: nil))
        await eventually { controller.status == .idle }
        XCTAssertEqual(bridge.calls.last, .deactivate)
        XCTAssertTrue(session.calls.isEmpty)
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

    /// An edit while Univocal has the reading paused: when its pill resumes
    /// (`state: playing`), the reading restarts on the edited text.
    func testTextChangeWhilePausedRestartsWhenUnivocalResumes() async {
        let session = await startPlaying()
        session.send(.state(.paused, detail: nil))
        await eventually { controller.status == .paused }
        controller.handle(.textChanged("Changed. Again.", startOffset: 9, generation: 2), from: page)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(backend.requests.count, 1, "no restart while paused")
        session.send(.state(.playing, detail: nil))
        await eventually { backend.requests.count == 2 }
        XCTAssertEqual(backend.requests[1].text, "Changed. Again.")
        XCTAssertEqual(backend.requests[1].startOffset, 9)
        await eventually { session.calls == ["stop"] }
        await eventually { bridge.calls.last == .activate(2) }
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
        XCTAssertFalse(controller.canStart(documentReady: true))
        controller.readAloud()
        XCTAssertEqual(opened, [UnivocalLocator.downloadURL])
        XCTAssertFalse(bridge.calls.contains { if case .requestText = $0 { return true } else { return false } })

        // Installed meanwhile: the next click reads.
        backend.installed = true
        controller.readAloud()
        XCTAssertEqual(controller.status, .starting(nil))
    }

    func testAwaitingConsentThenDenied() async {
        backend.hold = true
        backend.error = UnivocalError(code: .consentDenied, reason: "user")
        controller.readAloud()
        guard case .requestText(let request)? = bridge.calls.last else { return XCTFail("no requestText") }
        controller.handle(.text(Self.text, generation: 1, request: request), from: page)
        await eventually { backend.isHolding }
        backend.sendState(.launching)
        await eventually { controller.status == .starting("Starting Univocal…") }
        backend.sendState(.awaitingConsent)
        await eventually { controller.status == .awaitingConsent }
        XCTAssertEqual(controller.helpText, "Waiting for approval in Univocal…")
        XCTAssertFalse(controller.canStart(documentReady: true))
        backend.release()
        await eventually { controller.status == .unauthorized(ReadAloudController.consentMessage(reason: "user")) }

        // Retry asks again.
        controller.readAloud()
        XCTAssertEqual(controller.status, .starting(nil))
        XCTAssertEqual(bridge.calls.filter { if case .requestText = $0 { return true } else { return false } }.count, 2)
    }

    func testLaunchFailureShowsMessage() async {
        backend.error = UnivocalError(code: .launchTimedOut)
        controller.readAloud()
        guard case .requestText(let request)? = bridge.calls.last else { return XCTFail("no requestText") }
        controller.handle(.text(Self.text, generation: 1, request: request), from: page)
        await eventually { controller.status == .failed("Univocal didn't start") }
    }

    func testStopWhileStartingStopsTheLateSession() async {
        backend.hold = true
        controller.readAloud()
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
        controller.readAloud()
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
        lonely.readAloud()
        XCTAssertEqual(lonely.status, .failed("Show the preview to read aloud"))
    }

    func testInAppCommandStartsAtTheTop() async {
        await startPlaying()
        guard case .requestText(let request)? = bridge.calls.first(where: {
            if case .requestText = $0 { return true } else { return false }
        }) else { return XCTFail("no requestText") }
        XCTAssertNil(bridge.prefers[request])
        XCTAssertEqual(backend.answering, [nil])
    }

    // MARK: Univocal's hotkey (SPEC §16)

    private func hotkey(_ id: String = "h1", prefer: UnivocalReadRequest.Preference = .selection,
                        acceptedMs: Int = 5000) -> UnivocalReadRequest {
        UnivocalReadRequest(id: id, trigger: .hotkey, prefer: prefer, answerMs: 300, acceptedMs: acceptedMs,
                            receivedAt: .now)
    }

    /// The last `requestText` number sent to the page.
    private var lastTextRequest: Int? {
        for call in bridge.calls.reversed() {
            if case .requestText(let request) = call { return request }
        }
        return nil
    }

    private func expectDecline(_ reason: UnivocalDeclineReason, _ detail: String? = nil,
                               file: StaticString = #filePath, line: UInt = #line) async {
        await eventually("decline", file: file, line: line) { !backend.declines.isEmpty }
        XCTAssertEqual(backend.declines, [.init(id: "h1", reason: reason, detail: detail)], file: file, line: line)
        XCTAssertTrue(backend.requests.isEmpty, file: file, line: line)
    }

    func testHotkeyDeclinesWithoutDocument() async {
        controller.handleReadRequest(hotkey())
        await expectDecline(.noContent)
        XCTAssertEqual(controller.status, .idle)
    }

    func testHotkeyDeclinesWithoutWindow() async {
        controller.hotkeySource = { .noWindow }
        controller.handleReadRequest(hotkey())
        await expectDecline(.notFocused)
    }

    func testHotkeyDeclinesWhileTheFileLoads() async {
        controller.hotkeySource = { .loading }
        controller.handleReadRequest(hotkey())
        await expectDecline(.busy, "loading")
    }

    func testHotkeyDeclinesWhenTheEditorIsUnreachable() async {
        controller.hotkeySource = { .editor(nil) }
        controller.handleReadRequest(hotkey())
        await expectDecline(.other, "editView")
    }

    func testHotkeyDeclinesWhileAnInAppStartIsPending() async {
        controller.hotkeySource = { .preview }
        controller.readAloud()
        XCTAssertEqual(controller.status, .starting(nil))
        controller.handleReadRequest(hotkey())
        await expectDecline(.busy, "starting")
        XCTAssertEqual(controller.status, .starting(nil), "the user's own start goes on")
    }

    func testHotkeyDeclinesWithoutAPreviewPage() async {
        let lonelyBridge = FakeBridge()
        let lonely = ReadAloudController(backend: backend, bridge: lonelyBridge, openURL: { _ in })
        lonely.hotkeySource = { .preview }
        lonely.handleReadRequest(hotkey())
        await expectDecline(.busy, "noPreview")
    }

    func testHotkeyReadsThePreviewFromItsStartOffset() async {
        controller.hotkeySource = { .preview }
        controller.handleReadRequest(hotkey())
        XCTAssertEqual(controller.status, .starting(nil))
        let request = try! XCTUnwrap(lastTextRequest)
        XCTAssertEqual(bridge.prefers[request], .selection)
        await eventually("accept") { backend.log.contains("accept:h1") }

        controller.handle(.text(Self.text, generation: 3, request: request, startOffset: 13), from: page)
        await eventually("session") { backend.sessions.count == 1 }
        XCTAssertEqual(backend.log, ["accept:h1", "read:h1"], "readAccepted goes out before the read")
        XCTAssertEqual(backend.answering, ["h1"])
        XCTAssertEqual(backend.requests[0].startOffset, 13)
        XCTAssertEqual(backend.requests[0].text, Self.text)
        XCTAssertEqual(backend.requests[0].title, "Notes.md")
        await eventually("activate") { bridge.calls.contains(.activate(3)) }

        let session = backend.sessions[0]
        session.send(.state(.playing, detail: nil), .sentence(13..<24), .word(13..<19))
        await eventually { controller.status == .playing && controller.currentWord == 13..<19 }
        XCTAssertEqual(bridge.calls.last, .apply(13..<19, 13..<24))

        // Univocal toggles on the next press; PreviewMD only follows its state.
        session.send(.state(.paused, detail: nil))
        await eventually { controller.status == .paused }
        XCTAssertTrue(session.calls.isEmpty)
    }

    func testHotkeyPreferDocumentIsPassedToThePage() async {
        controller.hotkeySource = { .preview }
        controller.handleReadRequest(hotkey(prefer: .document))
        let request = try! XCTUnwrap(lastTextRequest)
        XCTAssertEqual(bridge.prefers[request], .document)
    }

    func testHotkeyRequestTooLateIsNotAFailure() async {
        controller.hotkeySource = { .preview }
        backend.error = UnivocalError(code: .unknownRequest, message: "expired")
        controller.handleReadRequest(hotkey())
        let request = try! XCTUnwrap(lastTextRequest)
        controller.handle(.text(Self.text, generation: 1, request: request, startOffset: 0), from: page)
        await eventually { backend.requests.count == 1 }
        await eventually { controller.status == .idle }
        XCTAssertEqual(bridge.calls.last, .deactivate)
    }

    func testHotkeyGivesUpWhenThePageIsTooSlow() async {
        controller.hotkeySource = { .preview }
        // 200 ms accepted budget − 150 ms margin: declines after ~50 ms.
        controller.handleReadRequest(hotkey(acceptedMs: 200))
        let request = try! XCTUnwrap(lastTextRequest)
        await expectDecline(.busy, "textTimeout")
        XCTAssertEqual(controller.status, .idle)
        // The late reply is dropped.
        controller.handle(.text(Self.text, generation: 1, request: request, startOffset: 0), from: page)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(backend.requests.isEmpty)
    }

    func testHotkeyOnAnEmptyPageDeclinesNoContent() async {
        controller.hotkeySource = { .preview }
        controller.handleReadRequest(hotkey())
        let request = try! XCTUnwrap(lastTextRequest)
        controller.handle(.error(code: "noContent", request: request), from: page)
        await expectDecline(.noContent)
        XCTAssertEqual(controller.status, .idle, "Univocal reads in its panel; nothing failed here")
    }

    func testHotkeyWhilePlayingReplacesTheSession() async {
        let old = await startPlaying()
        controller.hotkeySource = { .preview }
        controller.handleReadRequest(hotkey())
        XCTAssertEqual(controller.status, .starting(nil))
        let request = try! XCTUnwrap(lastTextRequest)
        controller.handle(.text(Self.text, generation: 2, request: request, startOffset: 6), from: page)
        await eventually { backend.sessions.count == 2 }
        XCTAssertEqual(backend.answering, [nil, "h1"])
        // Univocal already preempted the old one; its late events are ignored.
        old.send(.word(0..<5), .ended(.preempted, by: "Univocal"))
        let new = backend.sessions[1]
        new.send(.state(.playing, detail: nil))
        await eventually { controller.status == .playing }
        XCTAssertNotEqual(controller.currentWord, 0..<5)
    }

    func testNewerHotkeyReplacesAnUnansweredOne() async {
        controller.hotkeySource = { .preview }
        controller.handleReadRequest(hotkey("h0"))
        let first = try! XCTUnwrap(lastTextRequest)
        controller.handleReadRequest(hotkey("h1"))
        let second = try! XCTUnwrap(lastTextRequest)
        XCTAssertNotEqual(first, second)
        controller.handle(.text(Self.text, generation: 1, request: first, startOffset: 0), from: page)
        controller.handle(.text(Self.text, generation: 2, request: second, startOffset: 0), from: page)
        await eventually { backend.sessions.count == 1 }
        XCTAssertEqual(backend.answering, ["h1"])
        XCTAssertTrue(backend.declines.isEmpty)
    }

    // MARK: Hotkey in the editor

    func testHotkeyReadsTheEditorFromTheSelection() async {
        let text = "# Notes\n\nHello world. Second one."
        let editor = FakeEditor(text: text, selection: NSRange(location: 9, length: 5))
        controller.hotkeySource = { .editor(editor) }
        controller.handleReadRequest(hotkey())
        await eventually { backend.sessions.count == 1 }
        XCTAssertEqual(backend.log, ["read:h1"], "the text is in hand: no readAccepted")
        XCTAssertEqual(backend.requests[0].text, text)
        XCTAssertEqual(backend.requests[0].startOffset, 9)
        XCTAssertFalse(bridge.calls.contains { if case .requestText = $0 { return true } else { return false } })

        let session = backend.sessions[0]
        session.send(.state(.playing, detail: nil), .sentence(9..<21), .word(9..<14))
        await eventually { editor.paints.count == 2 }
        XCTAssertEqual(editor.paints, [.init(word: nil, sentence: 9..<21), .init(word: 9..<14, sentence: 9..<21)])
        XCTAssertFalse(bridge.calls.contains { if case .apply = $0 { return true } else { return false } })
        XCTAssertFalse(bridge.calls.contains { if case .activate = $0 { return true } else { return false } })

        // A page reload doesn't steal the session.
        controller.handle(.ready(highlightMode: "css-highlight"), from: page)
        XCTAssertFalse(bridge.calls.contains { if case .reattach = $0 { return true } else { return false } })

        session.send(.ended(.finished, by: nil))
        await eventually { controller.status == .idle }
        XCTAssertGreaterThanOrEqual(editor.clears, 1)
        XCTAssertNil(editor.onInvalidate)
    }

    func testHotkeyEditorStartsAtTheCaretOrTheVisibleLine() async {
        let text = "Line one.\nLine two.\nLine three."
        let caret = FakeEditor(text: text, selection: NSRange(location: 10, length: 0))
        controller.hotkeySource = { .editor(caret) }
        controller.handleReadRequest(hotkey())
        await eventually { backend.requests.count == 1 }
        XCTAssertEqual(backend.requests[0].startOffset, 10)

        let scrolled = FakeEditor(text: text, selection: NSRange(location: 10, length: 0))
        scrolled.visibleStart = 20
        controller.hotkeySource = { .editor(scrolled) }
        controller.handleReadRequest(hotkey("h2", prefer: .document))
        await eventually { backend.requests.count == 2 }
        XCTAssertEqual(backend.requests[1].startOffset, 20)
    }

    func testEditingStopsAnEditorReading() async {
        let editor = FakeEditor(text: "Hello world. Second one.")
        controller.hotkeySource = { .editor(editor) }
        controller.handleReadRequest(hotkey())
        await eventually { backend.sessions.count == 1 }
        let session = backend.sessions[0]
        session.send(.state(.playing, detail: nil))
        await eventually { controller.status == .playing }
        editor.onInvalidate?()
        XCTAssertEqual(controller.status, .idle)
        await eventually { session.calls == ["stop"] }
        XCTAssertGreaterThanOrEqual(editor.clears, 1)
    }

    func testViewModeSwitchStopsAnEditorReading() async {
        let editor = FakeEditor(text: "Hello world.")
        controller.hotkeySource = { .editor(editor) }
        controller.handleReadRequest(hotkey())
        await eventually { backend.sessions.count == 1 }
        controller.viewModeDidChange(toEdit: false)
        XCTAssertEqual(controller.status, .idle)
        await eventually { backend.sessions[0].calls == ["stop"] }
    }

    func testViewModeSwitchKeepsAPreviewReadingUnlessEdit() async {
        let session = await startPlaying()
        controller.viewModeDidChange(toEdit: false)
        XCTAssertEqual(controller.status, .playing)
        controller.viewModeDidChange(toEdit: true)
        XCTAssertEqual(controller.status, .idle)
        await eventually { session.calls == ["stop"] }
    }

    func testHotkeyEmptyEditorDeclinesNoContent() async {
        controller.hotkeySource = { .editor(FakeEditor(text: " \n\n ")) }
        controller.handleReadRequest(hotkey())
        await expectDecline(.noContent, "emptyEditor")
    }

    /// The bug from live QA: Edit view, editor not focused, SwiftUI's caret
    /// at the very end → the read started at the end and spoke 0 words.
    func testHotkeyUnfocusedEditorIgnoresItsCaretAtTheEnd() async {
        let text = "First line here.\nSecond line here."
        let editor = FakeEditor(text: text, selection: NSRange(location: (text as NSString).length, length: 0))
        editor.isFocused = false
        editor.visibleStart = 0
        controller.hotkeySource = { .editor(editor) }
        controller.handleReadRequest(hotkey())
        await eventually { backend.requests.count == 1 }
        XCTAssertEqual(backend.requests[0].startOffset, 0, "start at the first visible line, not the stale caret")
    }

    func testHotkeyFocusedCaretAtTheEndDeclinesNoContent() async {
        let text = "Everything was read already.  \n"
        let editor = FakeEditor(text: text, selection: NSRange(location: (text as NSString).length, length: 0))
        controller.hotkeySource = { .editor(editor) }
        controller.handleReadRequest(hotkey())
        await expectDecline(.noContent, "nothingAfterCursor")
        XCTAssertTrue(backend.requests.isEmpty, "never an empty read")
    }

    func testHotkeySelectionWinsEvenWhenTheEditorIsNotFocused() async {
        let text = "Alpha beta. Gamma delta."
        let editor = FakeEditor(text: text, selection: NSRange(location: 12, length: 5))
        editor.isFocused = false
        editor.visibleStart = 0
        controller.hotkeySource = { .editor(editor) }
        controller.handleReadRequest(hotkey())
        await eventually { backend.requests.count == 1 }
        XCTAssertEqual(backend.requests[0].startOffset, 12)
    }

    func testEditorStartOffsetRules() {
        let text = "One two. Three four.\n\n"           // 20 readable units, then blank lines
        func start(_ sel: NSRange, focused: Bool, prefer: UnivocalReadRequest.Preference = .selection,
                   visible: Int = 4) -> Int? {
            ReadAloudController.editorStartOffset(text: text, selection: sel, focused: focused,
                                                  prefer: prefer, visibleStart: visible)
        }
        XCTAssertEqual(start(NSRange(location: 9, length: 5), focused: false), 9, "selection wins")
        XCTAssertEqual(start(NSRange(location: 9, length: 0), focused: true), 9, "focused caret")
        XCTAssertEqual(start(NSRange(location: 9, length: 0), focused: false), 4, "unfocused caret → visible line")
        XCTAssertEqual(start(NSRange(location: 9, length: 5), focused: true, prefer: .document), 4)
        XCTAssertNil(start(NSRange(location: 20, length: 0), focused: true), "only blank lines follow")
        XCTAssertNil(start(NSRange(location: 22, length: 0), focused: true), "caret at the very end")
        XCTAssertNil(start(NSRange(location: 19, length: 0), focused: true), "only the full stop follows")
        XCTAssertEqual(start(NSRange(location: 999, length: 0), focused: false, visible: 999), nil, "clamped, then nothing")
        XCTAssertEqual(start(NSRange(location: NSNotFound, length: 0), focused: true, visible: 0), 0)
    }

    // MARK: Connection at launch, wake

    func testConnectsQuietlyAtLaunchAndWhenUnivocalStarts() async {
        controller.startHotkeyIntegration()
        controller.startHotkeyIntegration()   // once only
        await eventually { backend.log == ["connectIfAuthorized"] }
        backend.serverAppeared()
        await eventually { backend.log == ["connectIfAuthorized", "connectIfAuthorized"] }
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(controller.status, .idle, "a quiet connection changes nothing on screen")

        // Requests from the stream are answered.
        backend.sendRequest(hotkey())
        await expectDecline(.noContent)
    }

    func testWakeURLConnectsNamingTheRequest() async {
        controller.handleWakeURL(requestId: "w7")
        await eventually { backend.log == ["wake:w7"] }
        XCTAssertEqual(controller.status, .idle)
    }
}
