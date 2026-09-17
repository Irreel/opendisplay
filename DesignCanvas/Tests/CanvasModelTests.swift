import XCTest

// NOTE: this hostless bundle compiles DesignCanvas/iOS/Logic and
// DesignCanvas/Shared straight into it (see project.yml), so CanvasModel,
// CanvasReceiving and the wire types are available without an import.

/// Stands in for `StreamReceiver` behind `ReceiverAdapter`. Sends are recorded
/// and their completions held, so a test decides when — and whether — a write
/// lands, which is the only thing "sent" means on this wire (plan ruling 5).
private final class FakeReceiver: CanvasReceiving {
    var isConnected = true
    var supportsCanvas = true
    var captureMs: Int64? = 4_242

    private(set) var frozenCalls: [Bool] = []
    private(set) var sent: [[String: Any]] = []
    private var completions: [(type: String, answer: (Bool) -> Void)] = []

    func currentCaptureMs() -> Int64? { captureMs }

    func setFrozen(_ frozen: Bool) { frozenCalls.append(frozen) }

    func sendCanvas(_ message: [String: Any], completion: @escaping (Bool) -> Void) {
        sent.append(message)
        completions.append((message["type"] as? String ?? "", completion))
    }

    /// Answer the oldest unanswered send of that type — the annotation by
    /// default, since it is the one whose outcome drives the state machine.
    func completeSend(_ ok: Bool, ofType type: String = CanvasWire.annotation,
                      file: StaticString = #filePath, line: UInt = #line) {
        guard let index = completions.firstIndex(where: { $0.type == type }) else {
            return XCTFail("no \(type) is waiting for a completion", file: file, line: line)
        }
        completions.remove(at: index).answer(ok)
    }

    func messages(ofType type: String) -> [[String: Any]] {
        sent.filter { $0["type"] as? String == type }
    }
}

/// The two clocks `CanvasModel` is given, in a plain box so the closures that
/// read them are not tied to any actor: `uptime` drives the freeze deadline and
/// `wallMs` stamps the `t` of outgoing messages.
private final class CanvasTestClock {
    var uptime: TimeInterval = 100
    var wallMs: Double = 1_700_000_000_000
}

@MainActor
final class CanvasModelTests: XCTestCase {

    private var receiver = FakeReceiver()
    private var clock = CanvasTestClock()
    private var wallMs: Double {
        get { clock.wallMs }
        set { clock.wallMs = newValue }
    }

    private let zoom = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    private let viewport = CanvasViewport(width: 1180, height: 820, scale: 2)
    private let sketch = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    override func setUp() {
        super.setUp()
        receiver = FakeReceiver()
        clock = CanvasTestClock()
    }

    private func makeModel() -> CanvasModel {
        let clock = self.clock
        return CanvasModel(receiver: receiver, nowMs: { clock.wallMs }, uptime: { clock.uptime })
    }

    /// Enter Draw Mode and let the Mac confirm the freeze.
    private func drawingModel(strokes: Int = 1) -> CanvasModel {
        let model = makeModel()
        model.enterDrawMode(zoomRect: zoom, viewport: viewport)
        model.canvasMessage(type: CanvasWire.frozen, object: FrozenMessage(ok: true).json)
        model.strokesChanged(count: strokes)
        return model
    }

    // MARK: - Entering Draw Mode

    func test_enterDrawMode_freezesAtOnceAndAsksTheMacForTheSameFrame() {
        let model = makeModel()
        model.enterDrawMode(zoomRect: zoom, viewport: viewport)

        XCTAssertEqual(receiver.frozenCalls, [true])
        XCTAssertEqual(model.drawState, .freezing(deadline: 102))
        let freezes = receiver.messages(ofType: CanvasWire.freeze)
        XCTAssertEqual(freezes.count, 1)
        let freeze = FreezeMessage(json: freezes[0])
        XCTAssertEqual(freeze, FreezeMessage(captureMs: 4_242, zoomRect: zoom, t: wallMs))
    }

    func test_enterDrawMode_withoutAFrame_showsANoticeAndStaysLive() {
        receiver.captureMs = nil
        let model = makeModel()
        model.enterDrawMode(zoomRect: zoom, viewport: viewport)

        XCTAssertEqual(model.notice, .noFrame)
        XCTAssertEqual(model.drawState, .live)
        XCTAssertTrue(receiver.sent.isEmpty)
        XCTAssertTrue(receiver.frozenCalls.isEmpty)
    }

    func test_enterDrawMode_clearsALeftoverNotice() {
        let model = makeModel()
        model.enterDrawMode(zoomRect: zoom, viewport: viewport)
        model.canvasMessage(type: CanvasWire.frozen, object: FrozenMessage(ok: false).json)
        XCTAssertEqual(model.notice, .noFrame)

        model.enterDrawMode(zoomRect: zoom, viewport: viewport)
        XCTAssertNil(model.notice)
    }

    // MARK: - The freeze handshake

    func test_frozenOk_entersDrawing() {
        let model = makeModel()
        model.enterDrawMode(zoomRect: zoom, viewport: viewport)
        model.canvasMessage(type: CanvasWire.frozen, object: FrozenMessage(ok: true).json)

        XCTAssertEqual(model.drawState, .drawing)
        XCTAssertEqual(receiver.frozenCalls, [true])
    }

    func test_frozenNotOk_returnsLiveUnfreezesAndKeepsTheStrokes() {
        let model = makeModel()
        model.enterDrawMode(zoomRect: zoom, viewport: viewport)
        model.canvasMessage(type: CanvasWire.frozen, object: FrozenMessage(ok: false).json)

        XCTAssertEqual(model.drawState, .live)
        XCTAssertEqual(receiver.frozenCalls, [true, false])
        XCTAssertEqual(model.notice, .noFrame)
        XCTAssertFalse(model.shouldClearStrokes)
    }

    func test_tick_timesTheFreezeOutAfterTwoSeconds() {
        let model = makeModel()
        model.enterDrawMode(zoomRect: zoom, viewport: viewport)

        clock.uptime = 101.9
        model.tick()
        XCTAssertEqual(model.drawState, .freezing(deadline: 102))

        clock.uptime = 102
        model.tick()
        XCTAssertEqual(model.drawState, .live)
        XCTAssertEqual(model.notice, .freezeTimedOut)
        XCTAssertEqual(receiver.frozenCalls, [true, false])
        XCTAssertFalse(model.shouldClearStrokes)
    }

    // MARK: - Done

    func test_done_sendsTheSketchWithTheEntryZoomAndResumesSync() {
        let model = drawingModel(strokes: 3)
        model.note = "  align with the title baseline  "
        wallMs = 1_700_000_005_000
        model.done(sketchPNG: sketch)

        XCTAssertEqual(model.drawState, .sending)
        let annotations = receiver.messages(ofType: CanvasWire.annotation)
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(AnnotationMessage(json: annotations[0]),
                       AnnotationMessage(sketchPNG: sketch, zoomRect: zoom, viewport: viewport,
                                         note: "align with the title baseline",
                                         t: 1_700_000_005_000))
        XCTAssertEqual(receiver.frozenCalls, [true, false])
    }

    func test_done_withAnEmptyNote_sendsNoNote() {
        let model = drawingModel()
        model.note = "   "
        model.done(sketchPNG: sketch)

        let annotation = receiver.messages(ofType: CanvasWire.annotation).first
        XCTAssertNil(annotation?["note"])
    }

    func test_done_withoutAStroke_sendsNothing() {
        let model = drawingModel(strokes: 0)
        model.done(sketchPNG: sketch)

        XCTAssertEqual(model.drawState, .drawing)
        XCTAssertFalse(model.canSend)
        XCTAssertTrue(receiver.messages(ofType: CanvasWire.annotation).isEmpty)
    }

    func test_sendCompletingTrue_returnsLiveAndClearsTheStrokes() {
        let model = drawingModel()
        model.note = "note"
        model.done(sketchPNG: sketch)
        receiver.completeSend(true)

        XCTAssertEqual(model.drawState, .live)
        XCTAssertTrue(model.shouldClearStrokes)
        XCTAssertEqual(model.note, "")

        model.strokesCleared()
        XCTAssertFalse(model.shouldClearStrokes)
    }

    func test_sendCompletingFalse_retriesAndResendsTheSamePayloadOnTheNextHello() {
        let model = drawingModel()
        model.done(sketchPNG: sketch)
        receiver.completeSend(false)

        XCTAssertEqual(model.drawState, .retry)
        XCTAssertFalse(model.shouldClearStrokes)
        XCTAssertEqual(receiver.messages(ofType: CanvasWire.annotation).count, 1)

        // A later wall clock must not restamp the sketch: it is the same round.
        wallMs = 1_700_000_009_999
        model.welcomeReceived(canvas: true)

        XCTAssertEqual(model.drawState, .sending)
        let annotations = receiver.messages(ofType: CanvasWire.annotation)
        XCTAssertEqual(annotations.count, 2)
        XCTAssertEqual(AnnotationMessage(json: annotations[1]), AnnotationMessage(json: annotations[0]))

        receiver.completeSend(true)
        XCTAssertEqual(model.drawState, .live)
        XCTAssertTrue(model.shouldClearStrokes)
    }

    // MARK: - Leaving Draw Mode without sending

    func test_cancel_keepsTheStrokes() {
        let model = drawingModel(strokes: 2)
        model.cancel()

        XCTAssertEqual(model.drawState, .live)
        XCTAssertFalse(model.shouldClearStrokes)
        XCTAssertEqual(receiver.frozenCalls, [true, false])
    }

    func test_discard_dropsTheStrokes() {
        let model = drawingModel(strokes: 2)
        model.note = "never sent"
        model.discard()

        XCTAssertEqual(model.drawState, .live)
        XCTAssertTrue(model.shouldClearStrokes)
        XCTAssertEqual(model.note, "")
        XCTAssertEqual(receiver.frozenCalls, [true, false])
    }

    func test_rotated_leavesDrawModeAndKeepsTheStrokes() {
        let model = drawingModel(strokes: 2)
        model.rotated()

        XCTAssertEqual(model.drawState, .live)
        XCTAssertEqual(model.notice, .interruptedByRotation)
        XCTAssertFalse(model.shouldClearStrokes)
        XCTAssertEqual(receiver.frozenCalls, [true, false])
    }

    func test_linkLossWhileDrawing_leavesDrawModeWithANotice() {
        let model = drawingModel(strokes: 2)
        receiver.isConnected = false
        model.connectionChanged(connected: false)

        XCTAssertEqual(model.drawState, .live)
        XCTAssertEqual(model.notice, .interruptedByLinkLoss)
        XCTAssertFalse(model.shouldClearStrokes)
        XCTAssertEqual(receiver.frozenCalls, [true, false])
    }

    func test_dismissNotice_clearsIt() {
        let model = drawingModel()
        model.rotated()
        XCTAssertNotNil(model.notice)
        model.dismissNotice()
        XCTAssertNil(model.notice)
    }

    // MARK: - Rounds and replies

    private func round(_ id: String, _ status: RoundStatus, message: String? = nil,
                       note: String? = nil, prUrl: String? = nil) -> CanvasRound {
        CanvasRound(annotationId: id, createdAt: "2026-09-16T10:00:00.000Z", status: status,
                    message: message, prUrl: prUrl, note: note)
    }

    func test_rounds_replacesTheList() {
        let model = makeModel()
        model.canvasMessage(type: CanvasWire.rounds,
                            object: RoundsMessage(rounds: [round("a", .queued), round("b", .applied)]).json)
        XCTAssertEqual(model.rounds.map(\.annotationId), ["a", "b"])

        model.canvasMessage(type: CanvasWire.rounds,
                            object: RoundsMessage(rounds: [round("c", .sent)]).json)
        XCTAssertEqual(model.rounds, [round("c", .sent)])
    }

    func test_agentReply_updatesTheMatchingRoundInPlace() {
        let model = makeModel()
        model.canvasMessage(type: CanvasWire.rounds,
                            object: RoundsMessage(rounds: [round("a", .queued, note: "align it"),
                                                           round("b", .queued)]).json)
        model.canvasMessage(type: CanvasWire.agentReply,
                            object: AgentReplyMessage(annotationId: "b", status: .applied,
                                                      message: "done", prUrl: "https://example.com/pr/1",
                                                      t: wallMs).json)

        XCTAssertEqual(model.rounds.count, 2)
        XCTAssertEqual(model.rounds[0], round("a", .queued, note: "align it"))
        XCTAssertEqual(model.rounds[1], round("b", .applied, message: "done",
                                              prUrl: "https://example.com/pr/1"))
    }

    func test_agentReply_withoutTextKeepsTheTextTheRoundAlreadyHad() {
        let model = makeModel()
        model.canvasMessage(type: CanvasWire.rounds,
                            object: RoundsMessage(rounds: [round("a", .applied, message: "done",
                                                                 note: "align it")]).json)
        model.canvasMessage(type: CanvasWire.agentReply,
                            object: AgentReplyMessage(annotationId: "a", status: .needsInput,
                                                      message: nil, prUrl: nil, t: wallMs).json)

        XCTAssertEqual(model.rounds, [round("a", .needsInput, message: "done", note: "align it")])
    }

    func test_agentReply_forAnUnknownRoundInsertsItAtTheFront() {
        let model = makeModel()
        model.canvasMessage(type: CanvasWire.rounds,
                            object: RoundsMessage(rounds: [round("a", .queued)]).json)
        model.canvasMessage(type: CanvasWire.agentReply,
                            object: AgentReplyMessage(annotationId: "new", status: .queued,
                                                      message: nil, prUrl: nil, t: wallMs).json)

        XCTAssertEqual(model.rounds.map(\.annotationId), ["new", "a"])
        XCTAssertEqual(model.rounds[0].status, .queued)
    }

    func test_agentReply_keepsAtMostTwentyRounds() {
        let model = makeModel()
        let twenty = (0..<20).map { round("id-\($0)", .applied) }
        model.canvasMessage(type: CanvasWire.rounds, object: RoundsMessage(rounds: twenty).json)
        model.canvasMessage(type: CanvasWire.agentReply,
                            object: AgentReplyMessage(annotationId: "fresh", status: .queued,
                                                      message: nil, prUrl: nil, t: wallMs).json)

        XCTAssertEqual(model.rounds.count, 20)
        XCTAssertEqual(model.rounds.first?.annotationId, "fresh")
        XCTAssertEqual(model.rounds.last?.annotationId, "id-18")
    }

    func test_rounds_neverKeepsMoreThanTwenty() {
        let model = makeModel()
        let thirty = (0..<30).map { round("id-\($0)", .queued) }
        model.canvasMessage(type: CanvasWire.rounds, object: RoundsMessage(rounds: thirty).json)

        XCTAssertEqual(model.rounds.count, 20)
        XCTAssertEqual(model.rounds.last?.annotationId, "id-19")
    }

    // MARK: - Ping

    func test_ping_updatesTheChannelAndProject() {
        let model = makeModel()
        XCTAssertEqual(model.channel, ChannelState.none)
        XCTAssertNil(model.project)

        model.pingReceived(channel: "attached", project: "opendisplay")
        XCTAssertEqual(model.channel, .attached)
        XCTAssertEqual(model.project, "opendisplay")

        model.pingReceived(channel: "detached", project: nil)
        XCTAssertEqual(model.channel, .detached)
        XCTAssertNil(model.project)

        model.pingReceived(channel: "nonsense", project: nil)
        XCTAssertEqual(model.channel, ChannelState.none)
    }

    // MARK: - Draw Mode availability

    func test_canEnterDrawMode_needsALiveConnectedCanvasSession() {
        let model = makeModel()
        XCTAssertTrue(model.canEnterDrawMode)

        receiver.isConnected = false
        XCTAssertFalse(model.canEnterDrawMode)

        receiver.isConnected = true
        receiver.supportsCanvas = false
        XCTAssertFalse(model.canEnterDrawMode)

        receiver.supportsCanvas = true
        model.enterDrawMode(zoomRect: zoom, viewport: viewport)
        XCTAssertFalse(model.canEnterDrawMode)
    }

    func test_canSend_onlyWhileDrawingWithAStroke() {
        let model = makeModel()
        XCTAssertFalse(model.canSend)

        model.enterDrawMode(zoomRect: zoom, viewport: viewport)
        model.strokesChanged(count: 1)
        XCTAssertFalse(model.canSend, "freezing is not drawing (ruling 7)")

        model.canvasMessage(type: CanvasWire.frozen, object: FrozenMessage(ok: true).json)
        XCTAssertTrue(model.canSend)

        model.strokesChanged(count: 0)
        XCTAssertFalse(model.canSend)
    }

    // MARK: - Malformed input

    func test_malformedMessages_areIgnored() {
        let model = makeModel()
        model.canvasMessage(type: CanvasWire.rounds,
                            object: RoundsMessage(rounds: [round("a", .queued)]).json)
        model.enterDrawMode(zoomRect: zoom, viewport: viewport)

        model.canvasMessage(type: CanvasWire.frozen, object: [:])
        model.canvasMessage(type: CanvasWire.frozen, object: ["ok": "yes"])
        model.canvasMessage(type: CanvasWire.rounds, object: ["rounds": "nope"])
        model.canvasMessage(type: CanvasWire.rounds, object: ["rounds": [["annotationId": "x"]]])
        model.canvasMessage(type: CanvasWire.agentReply, object: ["annotationId": "a"])
        model.canvasMessage(type: CanvasWire.agentReply,
                            object: ["annotationId": "a", "status": "shipped", "t": wallMs])
        model.canvasMessage(type: "somethingElse", object: ["ok": true])

        XCTAssertEqual(model.drawState, .freezing(deadline: 102))
        XCTAssertEqual(model.rounds, [round("a", .queued)])
    }
}
