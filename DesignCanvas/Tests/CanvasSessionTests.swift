import CoreGraphics
import Foundation
import ImageIO
import XCTest

// NOTE: this hostless bundle compiles DesignCanvas/Shared and Mac/Engine
// straight into it (see project.yml), so everything under test is available
// without an import.

final class CanvasSessionTests: XCTestCase {

    // MARK: - helpers

    /// The Mac's frame ring, as a session sees it. Fresh per test.
    private let frames = FakeFrames()

    private func makeSession(
        daemon: FakeDaemon,
        status: CanvasStatus = CanvasStatus(),
        installID: String = "install-A",
        deviceName: String = "Zhao's iPad",
        sleep: @escaping (TimeInterval) async -> Void = { _ in await Task.yield() },
        now: @escaping () -> Date = Date.init
    ) -> CanvasSession {
        CanvasSession(
            installID: installID,
            deviceName: deviceName,
            daemon: daemon,
            status: status,
            frames: frames,
            workQueue: DispatchQueue(label: "test.canvas.work", qos: .utility),
            now: now,
            // Immediate, but cooperative by default: a test that parks a job in
            // its retry loop must not monopolise the executor while it waits.
            sleep: sleep
        )
    }

    private func freezeJSON(frame: UInt64) -> [String: Any] {
        FreezeMessage(frame: frame, t: 1_700_000_000_000).json
    }

    private func frozenReplies(_ outbound: FakeOutbound) -> [Bool] {
        outbound.objects(ofType: CanvasWire.frozen).compactMap { $0["ok"] as? Bool }
    }

    private static let testViewport = CanvasViewport(width: 1366, height: 1024, scale: 2)

    /// A sketch with nothing drawn on it: the composite is the frozen frame.
    /// The wire carries no empty sketch, so tests that only care about the
    /// round use this one.
    private lazy var blankSketch = sketchPNG(width: 40, height: 30, bandHeight: 0, fill: TestImages.RGBA(0, 0, 0))

    /// `t` identifies the round: the Mac drops a second `annotation` carrying a
    /// `t` it has already accepted as the iPad's byte-identical re-send (C1), so
    /// a test sending two *different* sketches gives them different stamps, as
    /// two real Done taps would.
    private func annotationJSON(
        viewport: CanvasViewport = CanvasSessionTests.testViewport,
        note: String? = nil,
        t: Double = 1_700_000_000_000
    ) -> [String: Any] {
        AnnotationMessage(sketchPNG: Data([0]), viewport: viewport, note: note, t: t).json
    }

    /// Sends an `annotation` the way the link delivers it: JSON plus the
    /// sketch as the attachment.
    private func annotate(_ session: CanvasSession, sketch: Data? = nil, note: String? = nil,
                          t: Double = 1_700_000_000_000) {
        session.receive(type: CanvasWire.annotation, object: annotationJSON(note: note, t: t),
                        attachment: sketch ?? blankSketch)
    }

    /// A sketch whose top `bandHeight` rows are opaque `fill` and whose rest
    /// is transparent, so a composite can be checked for "sketch on top,
    /// frame below".
    private func sketchPNG(width: Int, height: Int, bandHeight: Int, fill: TestImages.RGBA) -> Data {
        TestImages.pngData(
            TestImages.rectOnTransparentCGImage(
                width: width,
                height: height,
                rect: CGRect(x: 0, y: 0, width: Double(width), height: Double(bandHeight)),
                fill: fill
            )
        )
    }

    private func pngSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    /// Puts one frame in the ring and freezes on it, waiting until its capture
    /// has been posted so the held capture already carries an id.
    @discardableResult
    private func freeze(
        _ session: CanvasSession,
        daemon: FakeDaemon,
        frame: UInt64,
        colour: TestImages.RGBA,
        width: Int = 40,
        height: Int = 30,
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        waitForCapturePost: Bool = true
    ) -> Int {
        let posts = daemon.captureCalls.count
        frames.put(TestImages.solidBGRAPixelBuffer(width: width, height: height, color: colour),
                   frame: frame, capturedAt: capturedAt)
        session.receive(type: CanvasWire.freeze, object: freezeJSON(frame: frame), attachment: Data())
        if waitForCapturePost {
            waitUntil("the freeze capture to be posted") { daemon.captureCalls.count == posts + 1 }
        }
        return posts + 1
    }

    /// The iPad said hello on `outbound`.
    private func hello(_ session: CanvasSession, outbound: FakeOutbound) {
        session.attach(outbound)
    }

    // MARK: - freeze

    func test_freeze_hit_repliesFrozenOkImmediately_andPostsTheFrameAsACapture() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        frames.put(TestImages.solidBGRAPixelBuffer(width: 40, height: 30, color: TestImages.RGBA(10, 200, 30)), frame: 7)

        session.receive(type: CanvasWire.freeze, object: freezeJSON(frame: 7), attachment: Data())

        // The reply is sent before any PNG work, so it is already recorded,
        // and it names the frame it answers.
        XCTAssertEqual(frozenReplies(outbound), [true])
        XCTAssertEqual(outbound.objects(ofType: CanvasWire.frozen).first.flatMap(FrozenMessage.init(json:)),
                       FrozenMessage(frame: 7, ok: true))

        guard waitUntil("the freeze capture to be posted", { daemon.captureCalls.count == 1 }) else { return }
        let call = daemon.captureCalls[0]
        XCTAssertEqual(call.width, 40)
        XCTAssertEqual(call.height, 30)
        XCTAssertEqual(TestImages.pixel(inPNG: call.png, x: 5, y: 5), TestImages.RGBA(10, 200, 30))
    }

    /// The frame is matched exactly by number: the ring either holds the
    /// frame the iPad is looking at or the freeze misses.
    func test_freeze_ofAFrameTheRingDoesNotHold_repliesNotOk_andPostsNoCapture() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        frames.put(TestImages.solidBGRAPixelBuffer(width: 40, height: 30, color: TestImages.RGBA(200, 0, 0)), frame: 1)
        frames.put(TestImages.solidBGRAPixelBuffer(width: 20, height: 10, color: TestImages.RGBA(0, 0, 200)), frame: 2)

        session.receive(type: CanvasWire.freeze, object: freezeJSON(frame: 3), attachment: Data())

        XCTAssertEqual(frozenReplies(outbound), [false])

        // Positive marker: a freeze that does hit posts, and because the
        // upload pipeline is FIFO the miss would have been posted first.
        session.receive(type: CanvasWire.freeze, object: freezeJSON(frame: 2), attachment: Data())
        guard waitUntil("the hitting freeze's capture to be posted", { daemon.captureCalls.count == 1 }) else { return }
        XCTAssertEqual(frozenReplies(outbound), [false, true])
        XCTAssertEqual(daemon.captureCalls[0].width, 20)
        XCTAssertEqual(daemon.captureCalls.count, 1)
    }

    /// With no frame number there is nothing a `frozen` could answer; the
    /// iPad's own freeze deadline takes it out of FREEZING.
    func test_freeze_unparseable_repliesNothing_andPostsNoCapture() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        frames.put(TestImages.solidBGRAPixelBuffer(width: 8, height: 8, color: TestImages.RGBA(1, 2, 3)), frame: 1)

        session.receive(type: CanvasWire.freeze, object: ["frame": "not a number", "t": 1], attachment: Data())

        XCTAssertEqual(frozenReplies(outbound), [])
        XCTAssertTrue(daemon.captureCalls.isEmpty)
    }

    // MARK: - annotation

    func test_annotation_afterFreeze_uploadsTheCompositeWithCaptureIdDeviceNoteAndViewport() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = makeSession(daemon: daemon, installID: "install-A", deviceName: "Zhao's iPad",
                                  now: { createdAt })
        hello(session, outbound: outbound)
        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(0, 0, 200))

        let sketch = sketchPNG(width: 40, height: 30, bandHeight: 6, fill: TestImages.RGBA(255, 0, 0))
        annotate(session, sketch: sketch, note: "make this blue")
        XCTAssertEqual(session.pendingUploadCount, 1)

        guard waitUntil("the annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        let upload = daemon.annotationCalls[0]
        XCTAssertEqual(upload.sourceCaptureId, "capture-1")
        XCTAssertEqual(upload.deviceID, "install-A")
        XCTAssertEqual(upload.deviceName, "Zhao's iPad")
        XCTAssertNil(upload.zoomRect, "a round is the whole frame, uploaded as null — the channel's \"full frame\" (M1)")
        XCTAssertEqual(upload.viewport, CanvasSessionTests.testViewport)
        XCTAssertEqual(upload.note, "make this blue")
        XCTAssertEqual(upload.createdAt, createdAt)
        XCTAssertEqual(upload.sketchPNG, sketch)
        XCTAssertEqual(pngSize(upload.compositePNG), CGSize(width: 40, height: 30))
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 2), TestImages.RGBA(255, 0, 0))
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 20), TestImages.RGBA(0, 0, 200))

        waitUntil("the pending count to fall back to zero") { session.pendingUploadCount == 0 }
    }

    /// M2: "Captured at" is what the channel tells the model the frame is
    /// from. It was the daemon's own receipt time, minutes late for a round
    /// that waited out a retry — the frame's own capture time is right there
    /// in the ring entry.
    func test_freeze_postsTheCaptureStampedWithTheFramesOwnTime() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        // The app's clock is deliberately somewhere else entirely: the stamp
        // must come from the frame, not from "now".
        let session = makeSession(daemon: daemon, now: { Date(timeIntervalSince1970: 9_999) })
        hello(session, outbound: outbound)

        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(0, 0, 200),
               capturedAt: Date(timeIntervalSince1970: 1_700_000_123.456))

        XCTAssertEqual(daemon.captureCalls.count, 1)
        XCTAssertEqual(daemon.captureCalls[0].capturedAt,
                       Date(timeIntervalSince1970: 1_700_000_123.456))
    }

    /// An annotation with no sketch attached is not an annotation: the iPad
    /// never sends one, and there would be nothing to composite.
    func test_annotation_withNoAttachment_isDropped() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(0, 0, 200))

        session.receive(type: CanvasWire.annotation, object: annotationJSON(), attachment: Data())

        XCTAssertEqual(session.pendingUploadCount, 0)
        // Positive marker: the held capture is still there for a real one.
        annotate(session, t: 2)
        guard waitUntil("the real annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-1")
    }

    func test_annotation_withNoPriorFreeze_uploadsNothing() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)

        annotate(session)
        XCTAssertEqual(session.pendingUploadCount, 0)

        // Positive marker: an annotation that does have a freeze uploads, and
        // the pipeline is FIFO, so a dropped one would have been posted first.
        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(0, 0, 200))
        annotate(session, t: 2)
        guard waitUntil("the second annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls.count, 1)
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-1")
    }

    func test_secondFreezeBeforeDone_replacesTheHeldCapture() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)

        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(200, 0, 0))
        freeze(session, daemon: daemon, frame: 2, colour: TestImages.RGBA(0, 200, 0))
        XCTAssertEqual(daemon.captureCalls.count, 2)

        annotate(session)

        guard waitUntil("the annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        let upload = daemon.annotationCalls[0]
        XCTAssertEqual(upload.sourceCaptureId, "capture-2")
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 5), TestImages.RGBA(0, 200, 0))
    }

    func test_capturePostFailedAtFreeze_annotationPathPostsTheCaptureFirst() {
        let daemon = FakeDaemon()
        daemon.scriptCaptures([.failure(FakeDaemonFailure())])
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(0, 0, 200))

        annotate(session)

        guard waitUntil("the annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.captureCalls.count, 2)
        // The re-post carries the full, uncropped frame, not the composite.
        XCTAssertEqual(daemon.captureCalls[1].width, 40)
        XCTAssertEqual(daemon.captureCalls[1].height, 30)
        XCTAssertEqual(pngSize(daemon.captureCalls[1].png), CGSize(width: 40, height: 30))
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-2")
    }

    func test_failedUpload_isRetriedWithBackoff_andOrderIsPreservedAcrossQueuedAnnotations() {
        let daemon = FakeDaemon()
        daemon.scriptAnnotations([.failure(FakeDaemonFailure()), .failure(FakeDaemonFailure())])
        let outbound = FakeOutbound()
        var delays: [TimeInterval] = []
        let delaysLock = NSLock()
        let session = makeSession(daemon: daemon, sleep: { seconds in delaysLock.withLock { delays.append(seconds) } })
        hello(session, outbound: outbound)

        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(200, 0, 0))
        annotate(session)
        freeze(session, daemon: daemon, frame: 2, colour: TestImages.RGBA(0, 200, 0), waitForCapturePost: false)
        annotate(session, t: 1_700_000_005_000)

        guard waitUntil("both annotations to be uploaded", { daemon.annotationCalls.count == 4 }) else { return }
        XCTAssertEqual(
            daemon.annotationCalls.map(\.sourceCaptureId),
            ["capture-1", "capture-1", "capture-1", "capture-2"]
        )
        XCTAssertEqual(delaysLock.withLock { delays }, [0.5, 1.0])
        waitUntil("the pending count to fall back to zero") { session.pendingUploadCount == 0 }
    }

    func test_captureNotFound_repostsTheCaptureThenTheAnnotationSucceeds() {
        let daemon = FakeDaemon()
        daemon.scriptAnnotations([.failure(DaemonClientError.captureNotFound)])
        let outbound = FakeOutbound()
        var delays: [TimeInterval] = []
        let delaysLock = NSLock()
        let session = makeSession(daemon: daemon, sleep: { seconds in delaysLock.withLock { delays.append(seconds) } })
        hello(session, outbound: outbound)
        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(0, 0, 200))

        annotate(session)

        guard waitUntil("the retried annotation to be uploaded", { daemon.annotationCalls.count == 2 }) else { return }
        XCTAssertEqual(daemon.captureCalls.count, 2)
        XCTAssertEqual(daemon.annotationCalls.map(\.sourceCaptureId), ["capture-1", "capture-2"])
        // Re-posting after .captureNotFound retries at once, with no backoff.
        XCTAssertEqual(delaysLock.withLock { delays }, [])
    }

    func test_undecodableSketch_isDropped_andLaterJobsStillRun() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)

        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(200, 0, 0))
        annotate(session, sketch: Data([0x01, 0x02, 0x03, 0x04]))

        freeze(session, daemon: daemon, frame: 2, colour: TestImages.RGBA(0, 200, 0), waitForCapturePost: false)
        annotate(session, t: 1_700_000_005_000)

        guard waitUntil("the second annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-2")
        waitUntil("the pending count to fall back to zero") { session.pendingUploadCount == 0 }
    }

    // MARK: - hello and the rounds snapshot

    private func round(
        _ id: String,
        status: RoundStatus = .applied,
        message: String? = nil,
        prUrl: String? = nil,
        note: String? = nil
    ) -> CanvasRound {
        CanvasRound(
            annotationId: id,
            createdAt: "2026-09-16T12:00:00.000Z",
            status: status,
            message: message,
            prUrl: prUrl,
            note: note
        )
    }

    func test_hello_fetchesTheDevicesRounds_andSendsThemAsASnapshot() throws {
        let daemon = FakeDaemon()
        let rounds = [
            round("a2", status: .queued),
            round("a1", status: .applied, message: "done", prUrl: "https://example.test/pr/1", note: "make it blue"),
        ]
        daemon.scriptRounds(.success(rounds))
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon, installID: "install-A")

        hello(session, outbound: outbound)

        guard waitUntil("the rounds snapshot to be sent", { outbound.objects(ofType: CanvasWire.rounds).count == 1 }) else { return }
        XCTAssertEqual(daemon.roundsCalls.count, 1)
        XCTAssertEqual(daemon.roundsCalls[0].deviceID, "install-A")
        XCTAssertEqual(daemon.roundsCalls[0].limit, CanvasWire.roundsSnapshotLimit)

        let object = try XCTUnwrap(outbound.objects(ofType: CanvasWire.rounds).first)
        XCTAssertEqual(RoundsMessage(json: object), RoundsMessage(rounds: rounds))
    }

    func test_hello_withAFailingDaemon_sendsAnEmptySnapshot() throws {
        let daemon = FakeDaemon()
        daemon.scriptRounds(.failure(FakeDaemonFailure()))
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)

        hello(session, outbound: outbound)

        guard waitUntil("the rounds snapshot to be sent", { outbound.objects(ofType: CanvasWire.rounds).count == 1 }) else { return }
        let object = try XCTUnwrap(outbound.objects(ofType: CanvasWire.rounds).first)
        XCTAssertEqual(RoundsMessage(json: object), RoundsMessage(rounds: []))
    }

    /// The daemon never replays `round.updated`, so an update emitted while
    /// the engine's stream was down is gone for good. A reconnect therefore
    /// repeats what hello sends (I2).
    func test_resendSnapshot_sendsTheSnapshotAgain() throws {
        let daemon = FakeDaemon()
        let rounds = [round("a1", status: .applied, message: "done")]
        daemon.scriptRounds(.success(rounds))
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon, installID: "install-A")

        hello(session, outbound: outbound)
        guard waitUntil("hello's snapshot to be sent", { outbound.objects(ofType: CanvasWire.rounds).count == 1 }) else { return }

        session.resendSnapshot()

        guard waitUntil("the resent snapshot", { outbound.objects(ofType: CanvasWire.rounds).count == 2 }) else { return }
        XCTAssertEqual(daemon.roundsCalls.map(\.deviceID), ["install-A", "install-A"])
        let object = try XCTUnwrap(outbound.objects(ofType: CanvasWire.rounds).last)
        XCTAssertEqual(RoundsMessage(json: object), RoundsMessage(rounds: rounds))
    }

    func test_resendSnapshot_withNoLink_sendsNothing() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)

        // No hello yet: there is nowhere to send it.
        session.resendSnapshot()
        XCTAssertTrue(daemon.roundsCalls.isEmpty)

        hello(session, outbound: outbound)
        guard waitUntil("hello's snapshot to be sent", { outbound.objects(ofType: CanvasWire.rounds).count == 1 }) else { return }
        session.detach(outbound)

        session.resendSnapshot()
        XCTAssertEqual(daemon.roundsCalls.count, 1, "nothing to send it down")
        XCTAssertEqual(outbound.objects(ofType: CanvasWire.rounds).count, 1)
    }

    // MARK: - deliver

    private func agentReplies(_ outbound: FakeOutbound) -> [[String: Any]] {
        outbound.objects(ofType: CanvasWire.agentReply)
    }

    func test_deliver_forThisDevice_sendsAnAgentReplyWithATruncatedMessage() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon, installID: "install-A",
                                  now: { Date(timeIntervalSince1970: 1_700_000_000) })
        hello(session, outbound: outbound)

        let long = String(repeating: "é", count: 4_000)   // 8000 UTF-8 bytes
        session.deliver(RoundUpdate(
            deviceID: "install-A",
            round: round("a1", status: .needsInput, message: long, prUrl: "https://example.test/pr/7")
        ))

        let replies = agentReplies(outbound)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?["annotationId"] as? String, "a1")
        XCTAssertEqual(replies.first?["status"] as? String, "needs_input")
        XCTAssertEqual(replies.first?["prUrl"] as? String, "https://example.test/pr/7")
        XCTAssertEqual(replies.first?["t"] as? Double, 1_700_000_000_000)
        let message = replies.first?["message"] as? String
        XCTAssertEqual(message?.utf8.count, CanvasWire.replyMessageMaxBytes)
        XCTAssertEqual(message, String(repeating: "é", count: CanvasWire.replyMessageMaxBytes / 2))
    }

    func test_deliver_forAnotherDevice_sendsNothing() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon, installID: "install-A")
        hello(session, outbound: outbound)

        session.deliver(RoundUpdate(deviceID: "install-B", round: round("a1")))
        XCTAssertEqual(agentReplies(outbound).count, 0)

        // Positive marker: the same relay does fire for this device.
        session.deliver(RoundUpdate(deviceID: "install-A", round: round("a2")))
        XCTAssertEqual(agentReplies(outbound).map { $0["annotationId"] as? String }, ["a2"])
    }

    func test_deliver_afterTheLinkDropped_sendsNothing() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon, installID: "install-A")
        hello(session, outbound: outbound)
        session.detach(outbound)

        session.deliver(RoundUpdate(deviceID: "install-A", round: round("a1")))

        XCTAssertEqual(agentReplies(outbound).count, 0)
    }

    /// A link that drops reports it late, after the iPad has already said
    /// hello on the next one: the late report must not cut off the new link.
    func test_detachingAnOldLink_leavesTheNewOneAttached() {
        let daemon = FakeDaemon()
        let old = FakeOutbound()
        let new = FakeOutbound()
        let session = makeSession(daemon: daemon, installID: "install-A")
        hello(session, outbound: old)
        hello(session, outbound: new)

        session.detach(old)
        session.deliver(RoundUpdate(deviceID: "install-A", round: round("a1")))

        XCTAssertEqual(agentReplies(new).map { $0["annotationId"] as? String }, ["a1"])
        XCTAssertEqual(agentReplies(old).count, 0)
    }

    // MARK: - a link drop, and the reconnect that finishes the round (C1)

    /// The iPad answers a link loss in SENDING by keeping the sketch and
    /// re-sending it after the next `hello` (ruling 5). A Mac that forgot its
    /// freeze capture on the drop would then log "no freeze capture is held"
    /// and bin a sketch the device shows as sent. The session is the iPad's
    /// for the app's life, so the reconnect — a new link — finds it.
    func test_linkDrop_keepsTheHeldFreezeCapture_soAResentAnnotationStillUploads() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(200, 0, 0))

        // Twice: one drop can be reported more than once.
        session.detach(outbound)
        session.detach(outbound)

        let reconnected = FakeOutbound()
        hello(session, outbound: reconnected)
        annotate(session)

        guard waitUntil("the resent annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-1")
        XCTAssertEqual(daemon.captureCalls.count, 1, "the frame is not posted a second time")
    }

    /// The iPad re-sends byte-identical bytes, so `t` is stable: a `t` this Mac
    /// has already accepted is the same round arriving twice, not a second one.
    func test_aReSentAnnotationWithTheSameT_isUploadedOnlyOnce_acrossAReconnect() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(200, 0, 0))

        annotate(session, t: 4_242)
        guard waitUntil("the first annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }

        // The write's completion never reached the iPad, so it re-sends on the
        // next link.
        session.detach(outbound)
        let reconnected = FakeOutbound()
        hello(session, outbound: reconnected)
        annotate(session, t: 4_242)

        // Positive marker: a genuinely new round (a different `t`) still uploads,
        // and the pipeline is FIFO, so a duplicate would have gone first.
        freeze(session, daemon: daemon, frame: 2, colour: TestImages.RGBA(0, 200, 0), waitForCapturePost: false)
        annotate(session, t: 5_000)

        guard waitUntil("the next round to be uploaded", { daemon.annotationCalls.count == 2 }) else { return }
        XCTAssertEqual(daemon.annotationCalls.map(\.sourceCaptureId), ["capture-1", "capture-2"])
    }

    /// A held full-resolution frame must not be pinned for ever by a device
    /// that never came back to finish its round.
    func test_aHeldCaptureOlderThanTenMinutes_isNotUsed() {
        let daemon = FakeDaemon()
        let clock = TestClock()
        clock.current = Date(timeIntervalSince1970: 1_700_000_000)
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon, now: clock.now)
        hello(session, outbound: outbound)
        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(200, 0, 0))
        session.detach(outbound)

        clock.advance(CanvasSession.heldCaptureExpiry + 1)

        let reconnected = FakeOutbound()
        hello(session, outbound: reconnected)
        annotate(session)

        // Positive marker: a fresh freeze is used, and the pipeline is FIFO, so
        // the expired one would have uploaded first.
        freeze(session, daemon: daemon, frame: 3, colour: TestImages.RGBA(0, 0, 200))
        annotate(session, t: 1_700_000_009_000)

        guard waitUntil("the annotation on the fresh capture to be uploaded", {
            daemon.annotationCalls.count == 1
        }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-2")
    }

    func test_linkDrop_keepsQueuedUploads_andTheSameFrameCanBeFrozenAgain() {
        let daemon = FakeDaemon()
        daemon.scriptAnnotations([.failure(FakeDaemonFailure())])
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)

        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(200, 0, 0))
        annotate(session)

        // Twice: one drop can be reported more than once.
        session.detach(outbound)
        session.detach(outbound)

        // The queued upload survives the drop: it is still retried to success.
        guard waitUntil("the queued upload to finish its retry", { daemon.annotationCalls.count == 2 }) else { return }

        // The ring is the Mac's, not the link's, so the same frame can be
        // frozen again on the next link.
        let reconnected = FakeOutbound()
        hello(session, outbound: reconnected)
        session.receive(type: CanvasWire.freeze, object: freezeJSON(frame: 1), attachment: Data())
        XCTAssertEqual(frozenReplies(reconnected), [true])
        annotate(session, t: 1_700_000_005_000)

        guard waitUntil("the last annotation to be uploaded", { daemon.annotationCalls.count == 3 }) else { return }
        XCTAssertEqual(
            daemon.annotationCalls.map(\.sourceCaptureId),
            ["capture-1", "capture-1", "capture-2"]
        )
    }

    // MARK: - status

    private func statuses(_ outbound: FakeOutbound) -> [StatusMessage] {
        outbound.objects(ofType: CanvasWire.status).compactMap(StatusMessage.init(json:))
    }

    func test_hello_sendsTheStatus_withNoProjectWithoutATarget() {
        let session = makeSession(daemon: FakeDaemon())
        let outbound = FakeOutbound()

        hello(session, outbound: outbound)

        XCTAssertEqual(statuses(outbound), [StatusMessage(channel: .none, project: nil)])
    }

    /// The status is pushed when it changes, never on a timer: the app's 2 s
    /// health poll calls `sendStatus` far more often than anything changes.
    func test_sendStatus_sendsOnlyWhatChanged() {
        let status = CanvasStatus()
        let session = makeSession(daemon: FakeDaemon(), status: status)
        let outbound = FakeOutbound()
        hello(session, outbound: outbound)

        session.sendStatus()
        XCTAssertEqual(statuses(outbound).count, 1, "nothing changed since the hello")

        status.channelState = .attached
        let site = CanvasSessionEntry(id: "dc-a", folder: "site", title: nil, branch: nil,
                                      startedAt: "2026-10-05T10:00:00.000Z", lastReplyAt: nil, state: .idle)
        status.sessions = SessionsMessage(sessions: [site], target: "dc-a")
        session.sendStatus()
        session.sendStatus()

        XCTAssertEqual(statuses(outbound), [
            StatusMessage(channel: .none, project: nil),
            StatusMessage(channel: .attached, project: "site"),
        ])
    }

    /// What the last link was told says nothing about what the next one knows.
    func test_aNewHello_sendsTheStatusAgainEvenUnchanged() {
        let session = makeSession(daemon: FakeDaemon())
        let first = FakeOutbound()
        hello(session, outbound: first)
        session.detach(first)

        let second = FakeOutbound()
        hello(session, outbound: second)

        XCTAssertEqual(statuses(second), [StatusMessage(channel: .none, project: nil)])
    }

    func test_sendStatus_withNoLink_sendsNothing() {
        let status = CanvasStatus()
        let session = makeSession(daemon: FakeDaemon(), status: status)
        let outbound = FakeOutbound()
        hello(session, outbound: outbound)
        session.detach(outbound)

        status.channelState = .attached
        session.sendStatus()

        XCTAssertEqual(statuses(outbound).count, 1)
    }

    // MARK: - lifetime

    /// An upload that is still being retried must not keep its session alive:
    /// the pipeline carries only its own jobs, never the session or its link.
    func test_aSessionReleasedWhileAnUploadIsRetrying_stillDeallocates() {
        let daemon = FakeDaemon()
        daemon.setAnnotationsAlwaysFail(true)
        let outbound = FakeOutbound()
        var session: CanvasSession? = makeSession(daemon: daemon)
        weak let released = session

        hello(session!, outbound: outbound)
        freeze(session!, daemon: daemon, frame: 1, colour: TestImages.RGBA(0, 0, 200))
        annotate(session!)
        guard waitUntil("the upload to be retrying", { daemon.annotationCalls.count >= 2 }) else {
            daemon.setAnnotationsAlwaysFail(false)
            return
        }

        session = nil

        waitUntil("the released session to deallocate", { released == nil })
        // Let the surviving job finish so the retry loop does not outlive the test.
        daemon.setAnnotationsAlwaysFail(false)
        waitUntil("the surviving upload to land", { session == nil && daemon.annotationCalls.count >= 3 })
    }

    /// PRD D5: an accepted sketch is never lost because the Mac side went
    /// away. The iPad was told "sent" when it left DRAWING, so the round has
    /// to reach the daemon even though the device it came from has gone.
    func test_uploadsAcceptedBeforeTheSessionEnded_completeAfterIt_inOrder() {
        let daemon = FakeDaemon()
        daemon.setAnnotationsAlwaysFail(true)
        let outbound = FakeOutbound()
        var session: CanvasSession? = makeSession(daemon: daemon)
        weak let released = session

        hello(session!, outbound: outbound)
        freeze(session!, daemon: daemon, frame: 1, colour: TestImages.RGBA(200, 0, 0))
        annotate(session!)
        freeze(session!, daemon: daemon, frame: 2, colour: TestImages.RGBA(0, 200, 0), waitForCapturePost: false)
        annotate(session!, t: 1_700_000_005_000)
        XCTAssertEqual(session!.pendingUploadCount, 2)

        guard waitUntil("the first upload to be retrying", { daemon.annotationCalls.count >= 2 }) else {
            daemon.setAnnotationsAlwaysFail(false)
            return
        }

        session = nil
        guard waitUntil("the released session to deallocate", { released == nil }) else {
            daemon.setAnnotationsAlwaysFail(false)
            return
        }

        // The daemon comes back after the session is already gone.
        daemon.setAnnotationsAlwaysFail(false)
        guard waitUntil("both queued uploads to land", {
            daemon.annotationCalls.contains { $0.sourceCaptureId == "capture-2" }
        }) else { return }

        // Order held: every attempt at the first round, then the second one,
        // whose capture was posted by the queued job behind it.
        let uploaded = daemon.annotationCalls.map(\.sourceCaptureId)
        XCTAssertEqual(uploaded.last, "capture-2")
        XCTAssertEqual(uploaded.filter { $0 == "capture-2" }.count, 1)
        XCTAssertTrue(uploaded.dropLast().allSatisfy { $0 == "capture-1" })
        XCTAssertEqual(daemon.captureCalls.count, 2)
    }


    // MARK: - annotation on the blank canvas surface

    private func blankAnnotate(_ session: CanvasSession, sketch: Data, viewport: CanvasViewport,
                               note: String? = nil, t: Double = 1_700_000_000_000) {
        let object = AnnotationMessage(sketchPNG: sketch, viewport: viewport, note: note, t: t, base: .blank).json
        session.receive(type: CanvasWire.annotation, object: object, attachment: sketch)
    }

    func test_blankAnnotation_withNoFreeze_uploadsAWhitePageOfTheViewportsPixelSize() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = makeSession(daemon: daemon, installID: "install-A", now: { createdAt })
        hello(session, outbound: outbound)

        // 20x15 points at 2x: the sketch PNG and the page are both 40x30 pixels.
        let sketch = sketchPNG(width: 40, height: 30, bandHeight: 6, fill: TestImages.RGBA(255, 0, 0))
        blankAnnotate(session, sketch: sketch, viewport: CanvasViewport(width: 20, height: 15, scale: 2),
                      note: "three cards")

        guard waitUntil("the annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.captureCalls.count, 1, "the page is posted as the round's capture")
        XCTAssertEqual(daemon.captureCalls[0].width, 40)
        XCTAssertEqual(daemon.captureCalls[0].height, 30)
        XCTAssertEqual(daemon.captureCalls[0].capturedAt, createdAt)
        XCTAssertEqual(TestImages.pixel(inPNG: daemon.captureCalls[0].png, x: 5, y: 2), TestImages.RGBA(255, 255, 255))

        let upload = daemon.annotationCalls[0]
        XCTAssertEqual(upload.base, .blank)
        XCTAssertEqual(upload.sourceCaptureId, "capture-1")
        XCTAssertEqual(upload.deviceID, "install-A")
        XCTAssertNil(upload.zoomRect)
        XCTAssertEqual(upload.note, "three cards")
        XCTAssertEqual(pngSize(upload.compositePNG), CGSize(width: 40, height: 30))
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 2), TestImages.RGBA(255, 0, 0))
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 20), TestImages.RGBA(255, 255, 255))
    }

    func test_mirrorAnnotation_uploadsWithTheMirrorBase() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(0, 0, 200))
        annotate(session, sketch: sketchPNG(width: 40, height: 30, bandHeight: 6, fill: TestImages.RGBA(255, 0, 0)))
        guard waitUntil("the annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].base, .mirror)
    }

    func test_blankAnnotation_resent_isUploadedOnce() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        let sketch = sketchPNG(width: 40, height: 30, bandHeight: 6, fill: TestImages.RGBA(255, 0, 0))
        let viewport = CanvasViewport(width: 40, height: 30, scale: 1)

        blankAnnotate(session, sketch: sketch, viewport: viewport)
        blankAnnotate(session, sketch: sketch, viewport: viewport)

        guard waitUntil("the annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        waitUntil("the queue to drain") { session.pendingUploadCount == 0 }
        XCTAssertEqual(daemon.annotationCalls.count, 1)
    }

    /// A blank round must not eat the frame a mirror sketch is still waiting on.
    func test_blankAnnotation_leavesAHeldMirrorCaptureForItsOwnAnnotation() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        freeze(session, daemon: daemon, frame: 1, colour: TestImages.RGBA(0, 0, 200))

        let sketch = sketchPNG(width: 40, height: 30, bandHeight: 6, fill: TestImages.RGBA(255, 0, 0))
        blankAnnotate(session, sketch: sketch, viewport: CanvasViewport(width: 40, height: 30, scale: 1), t: 1)
        annotate(session, sketch: sketch, t: 2)

        guard waitUntil("both annotations to be uploaded", { daemon.annotationCalls.count == 2 }) else { return }
        XCTAssertEqual(daemon.annotationCalls.map(\.base), [.blank, .mirror])
        XCTAssertEqual(TestImages.pixel(inPNG: daemon.annotationCalls[1].compositePNG, x: 5, y: 20), TestImages.RGBA(0, 0, 200),
                       "the mirror sketch still lands on its frozen frame")
    }

    func test_blankAnnotation_withAnEmptyViewport_isDropped() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)
        blankAnnotate(session, sketch: blankSketch, viewport: CanvasViewport(width: 0, height: 30, scale: 2))
        XCTAssertEqual(session.pendingUploadCount, 0)
        XCTAssertTrue(daemon.annotationCalls.isEmpty)
    }

    func test_blankPageSize_isTheViewportInPixels_cappedPerSide() {
        XCTAssertEqual(CanvasSession.blankPageSize(for: CanvasViewport(width: 1366, height: 1024, scale: 2))?.width, 2732)
        XCTAssertEqual(CanvasSession.blankPageSize(for: CanvasViewport(width: 1366, height: 1024, scale: 2))?.height, 2048)
        XCTAssertEqual(CanvasSession.blankPageSize(for: CanvasViewport(width: 9000, height: 10, scale: 1))?.width, 4096)
        XCTAssertNil(CanvasSession.blankPageSize(for: CanvasViewport(width: 10, height: 0, scale: 2)))
        XCTAssertNil(CanvasSession.blankPageSize(for: CanvasViewport(width: 10, height: 10, scale: 0)))
    }
}
