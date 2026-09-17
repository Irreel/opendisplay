import CoreGraphics
import Foundation
import ImageIO
import XCTest

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine,
// DesignCanvas/Shared and Mac/SenderCanvasHooks.swift straight into it (see
// project.yml), so everything under test is available without an import.

final class CanvasSessionTests: XCTestCase {

    // MARK: - helpers

    private func makeSession(
        daemon: FakeDaemon,
        status: CanvasStatus = CanvasStatus(),
        deviceName: String = "Zhao's iPad",
        parking: CanvasCaptureParkingLot = CanvasCaptureParkingLot(),
        now: @escaping () -> Date = Date.init
    ) -> CanvasSession {
        CanvasSession(
            deviceName: deviceName,
            daemon: daemon,
            status: status,
            parking: parking,
            workQueue: DispatchQueue(label: "test.canvas.work", qos: .utility),
            now: now,
            // Immediate, but cooperative: a test that parks a job in its retry
            // loop must not monopolise the executor while it waits.
            sleep: { _ in await Task.yield() }
        )
    }

    private func freezeJSON(captureMs: Int64, zoomRect: NormalizedRect = .full) -> [String: Any] {
        var object = FreezeMessage(captureMs: captureMs, zoomRect: zoomRect, t: 1_700_000_000_000).json
        object["type"] = CanvasWire.freeze
        return object
    }

    private func frozenReplies(_ outbound: FakeOutbound) -> [Bool] {
        outbound.objects(ofType: CanvasWire.frozen).compactMap { $0["ok"] as? Bool }
    }

    private static let testViewport = CanvasViewport(width: 1366, height: 1024, scale: 2)

    /// `t` identifies the round: the Mac drops a second `annotation` carrying a
    /// `t` it has already accepted as the iPad's byte-identical re-send (C1), so
    /// a test sending two *different* sketches gives them different stamps, as
    /// two real Done taps would.
    private func annotationJSON(
        sketch: Data,
        zoomRect: NormalizedRect = .full,
        viewport: CanvasViewport = CanvasSessionTests.testViewport,
        note: String? = nil,
        t: Double = 1_700_000_000_000
    ) -> [String: Any] {
        var object = AnnotationMessage(
            sketchPNG: sketch,
            zoomRect: zoomRect,
            viewport: viewport,
            note: note,
            t: t
        ).json
        object["type"] = CanvasWire.annotation
        return object
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

    /// Feeds one frame and freezes on it, waiting until its capture has been
    /// posted so the held capture already carries an id.
    @discardableResult
    private func freeze(
        _ session: CanvasSession,
        outbound: FakeOutbound,
        daemon: FakeDaemon,
        captureMs: Int64,
        colour: TestImages.RGBA,
        width: Int = 40,
        height: Int = 30,
        waitForCapturePost: Bool = true
    ) -> Int {
        let posts = daemon.captureCalls.count
        session.canvasDidEncodeFrame(
            TestImages.solidBGRAPixelBuffer(width: width, height: height, color: colour),
            captureMs: captureMs
        )
        session.canvasDidReceive(type: CanvasWire.freeze, object: freezeJSON(captureMs: captureMs), outbound: outbound)
        if waitForCapturePost {
            waitUntil("the freeze capture to be posted") { daemon.captureCalls.count == posts + 1 }
        }
        return posts + 1
    }

    private func hello(_ session: CanvasSession, outbound: FakeOutbound, installID: String = "install-A") {
        session.canvasPeerDidHello(CanvasPeer(installID: installID, deviceKind: "ipad"), outbound: outbound)
    }

    // MARK: - freeze

    func test_freeze_hit_repliesFrozenOkImmediately_andPostsTheFrameAsACapture() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        let frame = TestImages.solidBGRAPixelBuffer(width: 40, height: 30, color: TestImages.RGBA(10, 200, 30))
        session.canvasDidEncodeFrame(frame, captureMs: 1_000)

        session.canvasDidReceive(type: CanvasWire.freeze, object: freezeJSON(captureMs: 1_000), outbound: outbound)

        // The reply is sent before any PNG work, so it is already recorded.
        XCTAssertEqual(frozenReplies(outbound), [true])

        guard waitUntil("the freeze capture to be posted", { daemon.captureCalls.count == 1 }) else { return }
        let call = daemon.captureCalls[0]
        XCTAssertEqual(call.width, 40)
        XCTAssertEqual(call.height, 30)
        XCTAssertEqual(TestImages.pixel(inPNG: call.png, x: 5, y: 5), TestImages.RGBA(10, 200, 30))
    }

    func test_freeze_100msOffTheRing_repliesNotOk_andPostsNoCapture() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        session.canvasDidEncodeFrame(
            TestImages.solidBGRAPixelBuffer(width: 40, height: 30, color: TestImages.RGBA(200, 0, 0)),
            captureMs: 1_000
        )
        session.canvasDidEncodeFrame(
            TestImages.solidBGRAPixelBuffer(width: 20, height: 10, color: TestImages.RGBA(0, 0, 200)),
            captureMs: 2_000
        )

        session.canvasDidReceive(type: CanvasWire.freeze, object: freezeJSON(captureMs: 1_100), outbound: outbound)

        XCTAssertEqual(frozenReplies(outbound), [false])

        // Positive marker: a freeze that does hit posts, and because the
        // upload pipeline is FIFO the miss would have been posted first.
        session.canvasDidReceive(type: CanvasWire.freeze, object: freezeJSON(captureMs: 2_000), outbound: outbound)
        guard waitUntil("the hitting freeze's capture to be posted", { daemon.captureCalls.count == 1 }) else { return }
        XCTAssertEqual(frozenReplies(outbound), [false, true])
        XCTAssertEqual(daemon.captureCalls[0].width, 20)
        XCTAssertEqual(daemon.captureCalls.count, 1)
    }

    func test_freeze_unparseable_repliesNotOk() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        session.canvasDidEncodeFrame(
            TestImages.solidBGRAPixelBuffer(width: 8, height: 8, color: TestImages.RGBA(1, 2, 3)),
            captureMs: 1_000
        )

        session.canvasDidReceive(
            type: CanvasWire.freeze,
            object: ["type": CanvasWire.freeze, "captureMs": "not a number", "t": 1],
            outbound: outbound
        )

        XCTAssertEqual(frozenReplies(outbound), [false])
        XCTAssertTrue(daemon.captureCalls.isEmpty)
    }

    // MARK: - annotation

    func test_annotation_afterFreeze_uploadsTheCompositeWithCaptureIdDeviceZoomNoteAndViewport() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = makeSession(daemon: daemon, deviceName: "Zhao's iPad", now: { createdAt })
        hello(session, outbound: outbound, installID: "install-A")
        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(0, 0, 200))

        let sketch = sketchPNG(width: 40, height: 30, bandHeight: 6, fill: TestImages.RGBA(255, 0, 0))
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: sketch, note: "make this blue"),
            outbound: outbound
        )
        XCTAssertEqual(session.pendingUploadCount, 1)

        guard waitUntil("the annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        let upload = daemon.annotationCalls[0]
        XCTAssertEqual(upload.sourceCaptureId, "capture-1")
        XCTAssertEqual(upload.deviceID, "install-A")
        XCTAssertEqual(upload.deviceName, "Zhao's iPad")
        XCTAssertEqual(upload.zoomRect, NormalizedRect.full)
        XCTAssertEqual(upload.viewport, CanvasSessionTests.testViewport)
        XCTAssertEqual(upload.note, "make this blue")
        XCTAssertEqual(upload.createdAt, createdAt)
        XCTAssertEqual(upload.sketchPNG, sketch)
        XCTAssertEqual(pngSize(upload.compositePNG), CGSize(width: 40, height: 30))
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 2), TestImages.RGBA(255, 0, 0))
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 20), TestImages.RGBA(0, 0, 200))

        waitUntil("the pending count to fall back to zero") { session.pendingUploadCount == 0 }
    }

    func test_annotation_withNoPriorFreeze_uploadsNothing() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)

        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: outbound
        )
        XCTAssertEqual(session.pendingUploadCount, 0)

        // Positive marker: an annotation that does have a freeze uploads, and
        // the pipeline is FIFO, so a dropped one would have been posted first.
        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(0, 0, 200))
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: outbound
        )
        guard waitUntil("the second annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls.count, 1)
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-1")
    }

    func test_secondFreezeBeforeDone_replacesTheHeldCapture() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound)

        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(200, 0, 0))
        freeze(session, outbound: outbound, daemon: daemon, captureMs: 2_000, colour: TestImages.RGBA(0, 200, 0))
        XCTAssertEqual(daemon.captureCalls.count, 2)

        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: outbound
        )

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
        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(0, 0, 200))

        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: outbound
        )

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
        let session = CanvasSession(
            deviceName: "Zhao's iPad",
            daemon: daemon,
            status: CanvasStatus(),
            workQueue: DispatchQueue(label: "test.canvas.work", qos: .utility),
            now: Date.init,
            sleep: { seconds in delaysLock.withLock { delays.append(seconds) } }
        )
        hello(session, outbound: outbound)

        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(200, 0, 0))
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: outbound
        )
        freeze(session, outbound: outbound, daemon: daemon, captureMs: 2_000, colour: TestImages.RGBA(0, 200, 0),
               waitForCapturePost: false)
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data(), t: 1_700_000_005_000),
            outbound: outbound
        )

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
        let session = CanvasSession(
            deviceName: "Zhao's iPad",
            daemon: daemon,
            status: CanvasStatus(),
            workQueue: DispatchQueue(label: "test.canvas.work", qos: .utility),
            now: Date.init,
            sleep: { seconds in delaysLock.withLock { delays.append(seconds) } }
        )
        hello(session, outbound: outbound)
        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(0, 0, 200))

        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: outbound
        )

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

        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(200, 0, 0))
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data([0x01, 0x02, 0x03, 0x04])),
            outbound: outbound
        )

        freeze(session, outbound: outbound, daemon: daemon, captureMs: 2_000, colour: TestImages.RGBA(0, 200, 0),
               waitForCapturePost: false)
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data(), t: 1_700_000_005_000),
            outbound: outbound
        )

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
        let session = makeSession(daemon: daemon)

        hello(session, outbound: outbound, installID: "install-A")

        guard waitUntil("the rounds snapshot to be sent", { outbound.payloads.count == 1 }) else { return }
        XCTAssertEqual(daemon.roundsCalls.count, 1)
        XCTAssertEqual(daemon.roundsCalls[0].deviceID, "install-A")
        XCTAssertEqual(daemon.roundsCalls[0].limit, CanvasWire.roundsSnapshotLimit)

        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outbound.payloads[0])) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, CanvasWire.rounds)
        XCTAssertEqual(RoundsMessage(json: object), RoundsMessage(rounds: rounds))
    }

    func test_hello_withAFailingDaemon_sendsAnEmptySnapshot() throws {
        let daemon = FakeDaemon()
        daemon.scriptRounds(.failure(FakeDaemonFailure()))
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)

        hello(session, outbound: outbound)

        guard waitUntil("the rounds snapshot to be sent", { outbound.payloads.count == 1 }) else { return }
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outbound.payloads[0])) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, CanvasWire.rounds)
        XCTAssertEqual(RoundsMessage(json: object), RoundsMessage(rounds: []))
    }

    // MARK: - deliver

    private func agentReplies(_ outbound: FakeOutbound) -> [[String: Any]] {
        outbound.objects(ofType: CanvasWire.agentReply)
    }

    func test_deliver_forThisDevice_sendsAnAgentReplyWithATruncatedMessage() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        hello(session, outbound: outbound, installID: "install-A")

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
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound, installID: "install-A")

        session.deliver(RoundUpdate(deviceID: "install-B", round: round("a1")))
        XCTAssertEqual(agentReplies(outbound).count, 0)

        // Positive marker: the same relay does fire for this device.
        session.deliver(RoundUpdate(deviceID: "install-A", round: round("a2")))
        XCTAssertEqual(agentReplies(outbound).map { $0["annotationId"] as? String }, ["a2"])
    }

    func test_deliver_afterTheLinkDropped_sendsNothing() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound, installID: "install-A")
        session.canvasLinkDidDrop()

        session.deliver(RoundUpdate(deviceID: "install-A", round: round("a1")))

        XCTAssertEqual(agentReplies(outbound).count, 0)
    }

    // MARK: - link drop and the parked freeze capture (C1)

    /// The iPad answers a link loss in SENDING by keeping the sketch and
    /// re-sending it after the next `hello` (ruling 5). A Mac that forgot its
    /// freeze capture on the drop would then log "no freeze capture is held"
    /// and bin a sketch the device shows as sent.
    func test_linkDrop_keepsTheHeldFreezeCapture_soAResentAnnotationStillUploads() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound, installID: "install-A")
        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(200, 0, 0))

        // Twice: one drop can be reported more than once.
        session.canvasLinkDidDrop()
        session.canvasLinkDidDrop()

        hello(session, outbound: outbound, installID: "install-A")
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: outbound
        )

        guard waitUntil("the resent annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-1")
        XCTAssertEqual(daemon.captureCalls.count, 1, "the frame is not posted a second time")
    }

    /// The sender tears the `DeviceSession` down after its 10 s grace, so the
    /// re-send usually lands on a brand new `CanvasSession`. The capture is
    /// parked per install id so that session inherits it.
    func test_aNewSessionForTheSameInstallIdInheritsTheParkedCapture() {
        let daemon = FakeDaemon()
        let parking = CanvasCaptureParkingLot()
        let outbound = FakeOutbound()
        let first = makeSession(daemon: daemon, parking: parking)
        hello(first, outbound: outbound, installID: "install-A")
        freeze(first, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(200, 0, 0))
        first.canvasLinkDidDrop()

        let second = makeSession(daemon: daemon, parking: parking)
        let secondOutbound = FakeOutbound()
        hello(second, outbound: secondOutbound, installID: "install-A")
        second.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: secondOutbound
        )

        guard waitUntil("the resent annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-1")
        XCTAssertEqual(daemon.captureCalls.count, 1)
    }

    func test_aSessionForADifferentInstallIdDoesNotInheritTheParkedCapture() {
        let daemon = FakeDaemon()
        let parking = CanvasCaptureParkingLot()
        let outbound = FakeOutbound()
        let first = makeSession(daemon: daemon, parking: parking)
        hello(first, outbound: outbound, installID: "install-A")
        freeze(first, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(200, 0, 0))
        first.canvasLinkDidDrop()

        let other = makeSession(daemon: daemon, parking: parking)
        let otherOutbound = FakeOutbound()
        hello(other, outbound: otherOutbound, installID: "install-B")
        other.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: otherOutbound
        )

        // Positive marker: install-A's own re-send still lands, and the
        // pipeline is FIFO, so install-B's would have been uploaded first.
        let again = makeSession(daemon: daemon, parking: parking)
        let againOutbound = FakeOutbound()
        hello(again, outbound: againOutbound, installID: "install-A")
        again.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: againOutbound
        )

        guard waitUntil("install-A's re-send to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].deviceID, "install-A")
    }

    /// The iPad re-sends byte-identical bytes, so `t` is stable: a `t` this Mac
    /// has already accepted is the same round arriving twice, not a second one.
    func test_aReSentAnnotationWithTheSameT_isUploadedOnlyOnce() {
        let daemon = FakeDaemon()
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound, installID: "install-A")
        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(200, 0, 0))

        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data(), t: 4_242),
            outbound: outbound
        )
        guard waitUntil("the first annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }

        // The write's completion never reached the iPad, so it re-sends.
        session.canvasLinkDidDrop()
        hello(session, outbound: outbound, installID: "install-A")
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data(), t: 4_242),
            outbound: outbound
        )

        // Positive marker: a genuinely new round (a different `t`) still uploads,
        // and the pipeline is FIFO, so a duplicate would have gone first.
        freeze(session, outbound: outbound, daemon: daemon, captureMs: 2_000, colour: TestImages.RGBA(0, 200, 0),
               waitForCapturePost: false)
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data(), t: 5_000),
            outbound: outbound
        )

        guard waitUntil("the next round to be uploaded", { daemon.annotationCalls.count == 2 }) else { return }
        XCTAssertEqual(daemon.annotationCalls.map(\.sourceCaptureId), ["capture-1", "capture-2"])
    }

    /// A parked full-resolution frame must not be pinned for ever by a device
    /// that never came back.
    func test_aParkedCaptureOlderThanTenMinutes_isNotUsed() {
        let daemon = FakeDaemon()
        let parking = CanvasCaptureParkingLot()
        let clock = TestClock()
        clock.current = Date(timeIntervalSince1970: 1_700_000_000)
        let outbound = FakeOutbound()
        let first = makeSession(daemon: daemon, parking: parking, now: clock.now)
        hello(first, outbound: outbound, installID: "install-A")
        freeze(first, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(200, 0, 0))
        first.canvasLinkDidDrop()

        clock.advance(601)

        let second = makeSession(daemon: daemon, parking: parking, now: clock.now)
        let secondOutbound = FakeOutbound()
        hello(second, outbound: secondOutbound, installID: "install-A")
        second.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: secondOutbound
        )

        // Positive marker: a freshly parked capture in the same lot is used, and
        // the pipeline is FIFO, so the expired one would have uploaded first.
        let third = makeSession(daemon: daemon, parking: parking, now: clock.now)
        let thirdOutbound = FakeOutbound()
        hello(third, outbound: thirdOutbound, installID: "install-A")
        freeze(third, outbound: thirdOutbound, daemon: daemon, captureMs: 3_000, colour: TestImages.RGBA(0, 0, 200))
        third.canvasLinkDidDrop()
        let fourth = makeSession(daemon: daemon, parking: parking, now: clock.now)
        let fourthOutbound = FakeOutbound()
        hello(fourth, outbound: fourthOutbound, installID: "install-A")
        fourth.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data(), t: 1_700_000_009_000),
            outbound: fourthOutbound
        )

        guard waitUntil("the annotation on the fresh capture to be uploaded", {
            daemon.annotationCalls.count == 1
        }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-2")
    }

    func test_linkDrop_keepsQueuedUploadsAndTheRing() {
        let daemon = FakeDaemon()
        daemon.scriptAnnotations([.failure(FakeDaemonFailure())])
        let outbound = FakeOutbound()
        let session = makeSession(daemon: daemon)
        hello(session, outbound: outbound, installID: "install-A")

        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(200, 0, 0))
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: outbound
        )

        // Twice: one drop can be reported more than once.
        session.canvasLinkDidDrop()
        session.canvasLinkDidDrop()

        // The queued upload survives the drop: it is still retried to success.
        guard waitUntil("the queued upload to finish its retry", { daemon.annotationCalls.count == 2 }) else { return }

        // The ring survives too, so the same frame can be frozen again.
        hello(session, outbound: outbound, installID: "install-A")
        freeze(session, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(0, 0, 200),
               waitForCapturePost: false)
        XCTAssertEqual(frozenReplies(outbound), [true, true])
        session.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data(), t: 1_700_000_005_000),
            outbound: outbound
        )

        guard waitUntil("the last annotation to be uploaded", { daemon.annotationCalls.count == 3 }) else { return }
        XCTAssertEqual(
            daemon.annotationCalls.map(\.sourceCaptureId),
            ["capture-1", "capture-1", "capture-2"]
        )
    }

    // MARK: - ping fields

    func test_canvasPingFields_mirrorCanvasStatus_withNoProjectKeyWhenUnselected() {
        let status = CanvasStatus()
        let session = makeSession(daemon: FakeDaemon(), status: status)

        XCTAssertEqual(session.canvasPingFields(), [CanvasWire.pingChannelKey: "none"])

        status.channelState = .attached
        status.projectName = "site"
        XCTAssertEqual(
            session.canvasPingFields(),
            [CanvasWire.pingChannelKey: "attached", CanvasWire.pingProjectKey: "site"]
        )

        status.channelState = .detached
        status.projectName = nil
        XCTAssertEqual(session.canvasPingFields(), [CanvasWire.pingChannelKey: "detached"])
    }

    // MARK: - lifetime

    /// A session whose device has gone is dead weight: it holds a frame ring
    /// of full-size deep copies and the link that fed it. Neither may be kept
    /// alive by an upload that is still being retried.
    func test_aSessionReleasedWhileAnUploadIsRetrying_stillDeallocates() {
        let daemon = FakeDaemon()
        daemon.setAnnotationsAlwaysFail(true)
        let outbound = FakeOutbound()
        var session: CanvasSession? = makeSession(daemon: daemon)
        weak let released = session

        hello(session!, outbound: outbound, installID: "install-A")
        freeze(session!, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(0, 0, 200))
        session!.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: outbound
        )
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

        hello(session!, outbound: outbound, installID: "install-A")
        freeze(session!, outbound: outbound, daemon: daemon, captureMs: 1_000, colour: TestImages.RGBA(200, 0, 0))
        session!.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data()),
            outbound: outbound
        )
        freeze(session!, outbound: outbound, daemon: daemon, captureMs: 2_000, colour: TestImages.RGBA(0, 200, 0),
               waitForCapturePost: false)
        session!.canvasDidReceive(
            type: CanvasWire.annotation,
            object: annotationJSON(sketch: Data(), t: 1_700_000_005_000),
            outbound: outbound
        )
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
}

