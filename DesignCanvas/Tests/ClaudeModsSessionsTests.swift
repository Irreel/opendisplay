import XCTest

// The session list end to end on the Swift side (`spec/technical_doc-ClaudeMods.md` sections 5
// and 7): the three wire additions, what the Mac engine does with them, and what the iPad's
// model makes of them. The daemon and the mod have their own tests under DesignCanvas/server
// and DesignCanvas/mod.

private func entry(
    _ id: String, folder: String = "acme", title: String? = nil, branch: String? = nil,
    startedAt: String = "2026-10-05T10:00:00.000Z", lastReplyAt: String? = nil,
    state: CanvasSessionState = .idle
) -> CanvasSessionEntry {
    CanvasSessionEntry(id: id, folder: folder, title: title, branch: branch,
                       startedAt: startedAt, lastReplyAt: lastReplyAt, state: state)
}

// MARK: - Wire

final class SessionsWireTests: XCTestCase {

    func testTypeStringsMatchTheSharedProtocolFile() {
        XCTAssertEqual(CanvasWire.sessions, "sessions")
        XCTAssertEqual(CanvasWire.selectSession, "selectSession")
        XCTAssertEqual(CanvasWire.annotationSessionKey, "session")
    }

    func testSessionsRoundTripsWithOptionalFieldsOmitted() {
        let message = SessionsMessage(
            sessions: [
                entry("dc-a", folder: "acme-web", title: "fix header", branch: "main",
                      lastReplyAt: "2026-10-05T10:05:00.000Z", state: .waiting),
                entry("dc-b", folder: "docs"),
            ],
            target: "dc-a"
        )
        let json = message.json
        XCTAssertEqual(SessionsMessage(json: json), message)
        let second = (json["sessions"] as? [[String: Any]])?[1]
        XCTAssertEqual(second.map { Set($0.keys) }, ["id", "folder", "startedAt", "state"], "no title, branch or reply time: no keys")
    }

    func testNoTargetIsAnAbsentKeyAndNeedsAPickOnlyWithSeveralSessions() {
        let several = SessionsMessage(sessions: [entry("dc-a"), entry("dc-b")], target: nil)
        XCTAssertNil(several.json["target"])
        XCTAssertTrue(several.needsPick)
        XCTAssertFalse(SessionsMessage(sessions: [entry("dc-a")], target: nil).needsPick, "one session is simply the target (X21)")
        XCTAssertFalse(SessionsMessage.empty.needsPick)
        XCTAssertFalse(SessionsMessage(sessions: [entry("dc-a"), entry("dc-b")], target: "dc-b").needsPick)
    }

    func testATargetThatNamesNoListedSessionReadsAsNone() {
        let parsed = SessionsMessage(json: ["sessions": [entry("dc-a").json, entry("dc-b").json], "target": "dc-gone"])
        XCTAssertNil(parsed?.target)
        XCTAssertEqual(parsed?.needsPick, true)
    }

    func testUnreadableEntriesAreSkippedAndAnUnknownStateReadsAsBusy() {
        let lenient = SessionsMessage(json: ["sessions": [
            ["id": "dc-a", "folder": "acme", "startedAt": "2026-10-05T10:00:00Z", "state": "pondering", "title": ""],
            ["folder": "no id"],
        ]])
        XCTAssertEqual(lenient?.sessions.map(\.id), ["dc-a"])
        XCTAssertEqual(lenient?.sessions.first?.state, .busy, "a state this build does not know promises nothing")
        XCTAssertNil(lenient?.sessions.first?.title, "an empty title is no title")
        XCTAssertNil(SessionsMessage(json: ["sessions": "nope"]))
        XCTAssertNil(SessionsMessage(json: ["sessions": [["id": "dc-a", "folder": "acme", "startedAt": "x"], "not an object"] as [Any]]),
                     "an array with a non-object in it is not a session list")
        XCTAssertNil(SessionsMessage(json: [:]))
    }

    func testTheDaemonsSnapshotShapeReadsToo() {
        // The daemon says `instance`; the wire says `id`. One parser reads both.
        let fromDaemon = CanvasSessionEntry(json: ["instance": "dc-a", "folder": "acme", "startedAt": "2026-10-05T10:00:00Z", "state": "idle", "cwd": "/work/acme"])
        XCTAssertEqual(fromDaemon?.id, "dc-a")
    }

    func testAnOversizeListStaysUnderTheSenderLimitAndKeepsTheTarget() throws {
        let long = String(repeating: "x", count: 400)
        let many = (0..<60).map { entry("dc-\($0)", folder: long, title: long, branch: long) }
        let message = SessionsMessage(sessions: many, target: "dc-59")
        var object = message.json
        object["type"] = CanvasWire.sessions
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertLessThan(data.count, CanvasWire.senderJSONLimit, "D23: never mistaken for video")

        let parsed = try XCTUnwrap(SessionsMessage(json: object))
        XCTAssertEqual(parsed.sessions.count, CanvasWire.sessionsMaxEntries)
        XCTAssertEqual(parsed.target, "dc-59", "the target survives the cut, or the iPad would ask for a pick")
        XCTAssertEqual(parsed.sessions[0].folder.count, CanvasWire.sessionFolderMaxCharacters)
        XCTAssertEqual(parsed.sessions[0].title?.count, CanvasWire.sessionTextMaxCharacters)
    }

    func testSelectSessionRoundTrips() {
        let message = SelectSessionMessage(id: "dc-b", t: 1_700_000_000_000)
        XCTAssertEqual(SelectSessionMessage(json: message.json), message)
        XCTAssertNil(SelectSessionMessage(json: ["id": "", "t": 1]))
        XCTAssertNil(SelectSessionMessage(json: ["id": "dc-b"]))
    }

    func testAnnotationCarriesItsSessionOnlyWhenItHasOne() {
        let png = Data([1, 2, 3])
        let viewport = CanvasViewport(width: 10, height: 10, scale: 2)
        let plain = AnnotationMessage(sketchPNG: png, zoomRect: .full, viewport: viewport, note: nil, t: 1)
        XCTAssertNil(plain.json[CanvasWire.annotationSessionKey], "an annotation with no session is byte-for-byte what it always was")

        let bound = AnnotationMessage(sketchPNG: png, zoomRect: .full, viewport: viewport, note: nil, t: 1, session: "dc-a")
        XCTAssertEqual(bound.json[CanvasWire.annotationSessionKey] as? String, "dc-a")
        XCTAssertEqual(AnnotationMessage(json: bound.json), bound)
        var blanked = bound.json
        blanked[CanvasWire.annotationSessionKey] = ""
        XCTAssertNil(AnnotationMessage(json: blanked)?.session)
    }

    func testTheReceiverRoutesSessionsInboundAndNeverSelectSession() {
        var state = CanvasReceiverState()
        state.handleWelcome(["canvas": true])
        XCTAssertEqual(state.route(type: "sessions"), .canvasMessage(type: "sessions"))
        XCTAssertEqual(state.route(type: "selectSession"), CanvasReceiverState.Routed.none, "that one only ever goes to the Mac")

        var plain = CanvasReceiverState()
        plain.handleWelcome([:])
        XCTAssertEqual(plain.route(type: "sessions"), CanvasReceiverState.Routed.none, "a plain OpenDisplay Mac has no canvas path")
    }
}

// MARK: - Mac engine

final class SessionsEngineTests: XCTestCase {

    private func makeSession(daemon: FakeDaemon, status: CanvasStatus) -> CanvasSession {
        CanvasSession(deviceName: "Studio iPad", daemon: daemon, status: status,
                      workQueue: DispatchQueue(label: "test.sessions.work", qos: .utility),
                      sleep: { _ in await Task.yield() })
    }

    private func hello(_ session: CanvasSession, _ outbound: FakeOutbound) {
        session.canvasPeerDidHello(CanvasPeer(installID: "install-A", deviceKind: "ipad"), outbound: outbound)
    }

    private let two = SessionsMessage(sessions: [entry("dc-a", folder: "acme-web"), entry("dc-b", folder: "docs")], target: "dc-b")

    func testHelloSendsTheSessionListAsItStands() throws {
        let status = CanvasStatus()
        status.sessions = two
        let outbound = FakeOutbound()
        let session = makeSession(daemon: FakeDaemon(), status: status)
        hello(session, outbound)

        let sent = try XCTUnwrap(outbound.objects(ofType: CanvasWire.sessions).first)
        XCTAssertEqual(SessionsMessage(json: sent), two)
    }

    func testHelloSendsAnEmptyListWhenNoSessionIsConnected() throws {
        let outbound = FakeOutbound()
        let session = makeSession(daemon: FakeDaemon(), status: CanvasStatus())
        hello(session, outbound)
        let sent = try XCTUnwrap(outbound.objects(ofType: CanvasWire.sessions).first)
        XCTAssertEqual(SessionsMessage(json: sent), .empty, "an iPad that had a list must be told it is gone")
    }

    func testThePingNamesTheTargetsFolderAndFallsBackToTheSelectedProject() {
        let status = CanvasStatus()
        status.projectName = "picked-in-the-menu"
        XCTAssertEqual(status.pingFields[CanvasWire.pingProjectKey], "picked-in-the-menu")
        status.sessions = two
        XCTAssertEqual(status.pingFields[CanvasWire.pingProjectKey], "docs", "where the next sketch actually goes")
        status.sessions = SessionsMessage(sessions: two.sessions, target: nil)
        XCTAssertEqual(status.pingFields[CanvasWire.pingProjectKey], "picked-in-the-menu")
    }

    func testSelectSessionAsksTheDaemonAsTheIPad() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon, status: CanvasStatus())
        hello(session, outbound)

        var message = SelectSessionMessage(id: "dc-a", t: 1).json
        message["type"] = CanvasWire.selectSession
        session.canvasDidReceive(type: CanvasWire.selectSession, object: message, outbound: outbound)

        guard waitUntil("the target to be set", { daemon.targetCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.targetCalls[0].instance, "dc-a")
        XCTAssertTrue(daemon.targetCalls[0].fromIPad)

        session.canvasDidReceive(type: CanvasWire.selectSession, object: ["type": CanvasWire.selectSession], outbound: outbound)
        XCTAssertEqual(daemon.targetCalls.count, 1, "an unparseable choice changes nothing")
    }

    func testAnAnnotationsSessionReachesTheUpload() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon, status: CanvasStatus())
        hello(session, outbound)

        let sketch = TestImages.pngData(TestImages.rectOnTransparentCGImage(
            width: 40, height: 30, rect: CGRect(x: 0, y: 0, width: 40, height: 6), fill: TestImages.RGBA(255, 0, 0)))
        func send(session id: String?, t: Double) {
            var object = AnnotationMessage(sketchPNG: sketch, zoomRect: .full,
                                           viewport: CanvasViewport(width: 20, height: 15, scale: 2),
                                           note: nil, t: t, base: .blank, session: id).json
            object["type"] = CanvasWire.annotation
            session.canvasDidReceive(type: CanvasWire.annotation, object: object, outbound: outbound)
        }
        send(session: "dc-a", t: 1)
        send(session: nil, t: 2)

        guard waitUntil("both annotations to be uploaded", { daemon.annotationCalls.count == 2 }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].session, "dc-a", "X23: bound to what the iPad showed at Done")
        XCTAssertNil(daemon.annotationCalls[1].session, "an older iPad names none; the daemon uses the target at arrival")
    }

    func testDaemonSnapshotDecodesAndKeepsWhatOnlyTheMacUses() {
        let json: [String: Any] = [
            "sessions": [[
                "instance": "dc-a", "sessionId": "s1", "cwd": "/work/acme", "folder": "acme",
                "startedAt": "2026-10-05T10:00:00.000Z", "state": "waiting", "launch": "nonce-1", "branch": "main",
            ]],
            "target": "dc-a",
        ]
        let decoded = DaemonSessions(json: json)
        XCTAssertEqual(decoded?.sessions.first?.launch, "nonce-1")
        XCTAssertEqual(decoded?.sessions.first?.cwd, "/work/acme")
        XCTAssertEqual(decoded?.message, SessionsMessage(
            sessions: [entry("dc-a", branch: "main", state: .waiting)], target: "dc-a"))
        XCTAssertNil(DaemonSessions(json: ["target": "dc-a"]))
    }

    @MainActor
    func testTheHubRelaysEachChangeToEveryIPadOnce() async throws {
        let daemon = FakeDaemon()
        let status = CanvasStatus()
        let hub = CanvasHub(daemon: daemon, status: status)
        let session = hub.makeSession(deviceName: "Studio iPad")
        let outbound = FakeOutbound()
        hello(session, outbound)
        XCTAssertEqual(outbound.objects(ofType: CanvasWire.sessions).count, 1, "the hello's own copy")

        hub.start()
        await Task.yield()
        let snapshot = DaemonSessions(
            sessions: [DaemonSession(entry: entry("dc-a", state: .waiting), cwd: "/work/acme", launch: nil)], target: "dc-a")
        for _ in 0..<50 where outbound.objects(ofType: CanvasWire.sessions).count < 2 {
            daemon.emitSessions(snapshot)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(status.sessions, snapshot.message)
        let relayed = outbound.objects(ofType: CanvasWire.sessions)
        XCTAssertEqual(relayed.count, 2, "a repeated snapshot (the stream replays on reconnect) is not re-sent")
        XCTAssertEqual(SessionsMessage(json: relayed[1])?.targetEntry?.state, .waiting, "X8 reaches the iPad as it happens")
        hub.stop()
    }
}

// MARK: - iPad model

private final class SessionsFakeReceiver: CanvasReceiving {
    var isConnected = true
    var supportsCanvas = true
    private(set) var sent: [[String: Any]] = []
    private var completions: [(Bool) -> Void] = []

    func currentCaptureMs() -> Int64? { 4_242 }
    func setFrozen(_ frozen: Bool) {}
    func sendCanvas(_ message: [String: Any], completion: @escaping (Bool) -> Void) {
        sent.append(message)
        completions.append(completion)
    }
    func messages(ofType type: String) -> [[String: Any]] { sent.filter { $0["type"] as? String == type } }
    func completeLastSend(_ ok: Bool) { completions.removeLast()(ok) }
}

@MainActor
final class SessionsModelTests: XCTestCase {

    private var receiver = SessionsFakeReceiver()
    private let sketch = Data([0x89, 0x50, 0x4E, 0x47])
    private let viewport = CanvasViewport(width: 1180, height: 820, scale: 2)

    override func setUp() {
        super.setUp()
        receiver = SessionsFakeReceiver()
    }

    private func drawingModel() -> CanvasModel {
        let model = CanvasModel(receiver: receiver, nowMs: { 1_700_000_000_000 }, uptime: { 100 })
        model.enterDrawMode(viewport: viewport)
        model.canvasMessage(type: CanvasWire.frozen, object: FrozenMessage(ok: true).json)
        model.strokesChanged(count: 1)
        return model
    }

    private func deliver(_ message: SessionsMessage, to model: CanvasModel) {
        model.canvasMessage(type: CanvasWire.sessions, object: message.json)
    }

    private let two = SessionsMessage(sessions: [entry("dc-a", folder: "acme-web"), entry("dc-b", folder: "docs")], target: "dc-a")

    func testWithNoSessionsMessageNothingChanges() {
        // A Mac that predates the session list never sends one.
        let model = drawingModel()
        XCTAssertTrue(model.canSend)
        model.done(sketchPNG: sketch)
        let sent = receiver.messages(ofType: CanvasWire.annotation)
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(sent[0][CanvasWire.annotationSessionKey], "the annotation is what it always was")
        XCTAssertFalse(model.waitingAtMac)
    }

    func testDoneStampsTheTargetShownAtThatMoment() {
        let model = drawingModel()
        deliver(two, to: model)
        XCTAssertEqual(model.targetSession?.folder, "acme-web")
        model.done(sketchPNG: sketch)
        XCTAssertEqual(receiver.messages(ofType: CanvasWire.annotation).last?[CanvasWire.annotationSessionKey] as? String, "dc-a")
    }

    func testAResendAfterALinkLossGoesToTheSameSessionEvenIfTheTargetMoved() {
        let model = drawingModel()
        deliver(two, to: model)
        model.done(sketchPNG: sketch)
        receiver.completeLastSend(false) // the link dropped mid-send
        XCTAssertEqual(model.drawState, .retry)

        // Reconnected; meanwhile the target moved to the other session.
        deliver(SessionsMessage(sessions: two.sessions, target: "dc-b"), to: model)
        model.welcomeReceived(canvas: true)
        let annotations = receiver.messages(ofType: CanvasWire.annotation)
        XCTAssertEqual(annotations.count, 2)
        XCTAssertEqual(annotations[1][CanvasWire.annotationSessionKey] as? String, "dc-a", "X23: a sketch already sent stays where it was sent")
    }

    func testSeveralSessionsAndNoTargetHoldDoneUntilAPick() {
        let model = drawingModel()
        deliver(SessionsMessage(sessions: two.sessions, target: nil), to: model)
        XCTAssertFalse(model.canSend, "X26")
        model.done(sketchPNG: sketch)
        XCTAssertTrue(receiver.messages(ofType: CanvasWire.annotation).isEmpty)
        XCTAssertEqual(model.drawState, .drawing, "the sketch is still there to send")

        model.selectSession("dc-b")
        XCTAssertEqual(receiver.messages(ofType: CanvasWire.selectSession).last?["id"] as? String, "dc-b")
        XCTAssertFalse(model.canSend, "nothing is assumed: the Mac's fresh list is what moves the target")

        deliver(SessionsMessage(sessions: two.sessions, target: "dc-b"), to: model)
        XCTAssertTrue(model.canSend)
        model.done(sketchPNG: sketch)
        XCTAssertEqual(receiver.messages(ofType: CanvasWire.annotation).last?[CanvasWire.annotationSessionKey] as? String, "dc-b")
    }

    func testSelectingTheCurrentTargetOrAnUnknownSessionSendsNothing() {
        let model = drawingModel()
        deliver(two, to: model)
        model.selectSession("dc-a")
        model.selectSession("dc-nowhere")
        XCTAssertTrue(receiver.messages(ofType: CanvasWire.selectSession).isEmpty)
    }

    func testWaitingAtTheMacFollowsTheTargetAndNamesTheNewestOpenRound() {
        let model = drawingModel()
        func round(_ id: String, _ status: RoundStatus) -> [String: Any] {
            CanvasRound(annotationId: id, createdAt: "2026-10-05T10:0\(id.count):00.000Z", status: status,
                        message: nil, prUrl: nil, note: nil).json
        }
        model.canvasMessage(type: CanvasWire.rounds, object: ["rounds": [round("newest", .sent), round("older", .queued), round("old", .applied)]])

        deliver(SessionsMessage(sessions: [entry("dc-a", state: .waiting), entry("dc-b")], target: "dc-b"), to: model)
        XCTAssertFalse(model.waitingAtMac, "another session waiting is not this one's news")
        XCTAssertNil(model.waitingRoundID)

        deliver(SessionsMessage(sessions: [entry("dc-a", state: .waiting), entry("dc-b")], target: "dc-a"), to: model)
        XCTAssertTrue(model.waitingAtMac)
        XCTAssertEqual(model.waitingRoundID, "newest")

        deliver(SessionsMessage(sessions: [entry("dc-a", state: .busy), entry("dc-b")], target: "dc-a"), to: model)
        XCTAssertFalse(model.waitingAtMac)
    }

    func testTheListIsDroppedWithTheLinkAndAnUnparseableOneIsIgnored() {
        let model = drawingModel()
        deliver(two, to: model)
        model.canvasMessage(type: CanvasWire.sessions, object: ["sessions": "nope"])
        XCTAssertEqual(model.sessions, two)

        receiver.isConnected = false
        model.connectionChanged(connected: false)
        XCTAssertEqual(model.sessions, .empty, "a list from a Mac that is gone names targets that cannot be reached")
    }
}
