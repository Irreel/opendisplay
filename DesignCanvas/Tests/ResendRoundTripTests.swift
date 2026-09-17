import CoreGraphics
import Foundation
import XCTest

// NOTE: this hostless bundle compiles DesignCanvas/iOS/Logic,
// DesignCanvas/Mac/Engine, DesignCanvas/Shared and Mac/SenderCanvasHooks.swift
// straight into it (see project.yml), so both halves of the round — the iPad's
// `CanvasModel` and the Mac's `CanvasSession`/`CanvasHub` — are available here
// without an import.
//
// Every other test in this bundle exercises one side of the wire against a
// fake of the other. This file is the one that drives BOTH real
// implementations against each other, because the resend contract is the one
// place where each side's own suite passed while the two disagreed (C1): the
// iPad re-sent only the `annotation` after a link loss, and the Mac had thrown
// the frozen frame away, so the sketch vanished while the chip said "Sketch
// kept — will resend".

/// The socket between the two halves.
///
/// What the model writes is handed to the Mac-side session verbatim, as the
/// real `StreamReceiver`/`MacSender` pair would. What the session writes back
/// is recorded rather than delivered, and the test pumps it into the model —
/// explicitly, so the ordering of a nested effect is visible in the test
/// rather than buried in a queue hop.
private final class Wire: CanvasReceiving, CanvasOutbound {
    var isConnected = true
    var supportsCanvas = true
    var captureMs: Int64? = 1_000

    /// The Mac-side session this iPad is currently connected to. Replaced by a
    /// fresh one when the sender rebuilds the session after a drop.
    var session: CanvasSession?
    /// While false a write never reaches the Mac and its completion answers
    /// false — which is all "the link went down mid-send" means (ruling 5).
    var linkUp = true

    private(set) var annotationWrites = 0
    private(set) var inbound: [[String: Any]] = []
    private var heldAnnotationCompletion: ((Bool) -> Void)?

    // MARK: - CanvasReceiving

    func currentCaptureMs() -> Int64? { captureMs }

    func setFrozen(_ frozen: Bool) {}

    func sendCanvas(_ message: [String: Any], completion: @escaping (Bool) -> Void) {
        let type = message["type"] as? String ?? ""
        if type == CanvasWire.annotation { annotationWrites += 1 }
        guard linkUp, let session else {
            completion(false)
            return
        }
        session.canvasDidReceive(type: type, object: message, outbound: self)
        // An annotation's completion is what "sent" means on the device, so the
        // test lands it deliberately; everything else completes at once.
        if type == CanvasWire.annotation {
            heldAnnotationCompletion = completion
        } else {
            completion(true)
        }
    }

    /// Completes the outstanding `annotation` write, as the socket does once
    /// the last byte is gone.
    func landAnnotationWrite() {
        let completion = heldAnnotationCompletion
        heldAnnotationCompletion = nil
        completion?(true)
    }

    // MARK: - CanvasOutbound

    @discardableResult
    func sendCanvasJSON(_ object: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              let payload = try? JSONSerialization.data(withJSONObject: object),
              payload.count < CanvasWire.senderJSONLimit else { return false }
        inbound.append(object)
        return true
    }

    @discardableResult
    func sendCanvasJSONData(_ data: Data) -> Bool {
        guard data.count < CanvasWire.senderJSONLimit else { return false }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            inbound.append(object)
        }
        return true
    }

    /// The oldest unread message of that type, removed.
    func take(_ type: String) -> [String: Any]? {
        guard let index = inbound.firstIndex(where: { $0["type"] as? String == type }) else { return nil }
        return inbound.remove(at: index)
    }
}

private final class WireClock {
    var uptime: TimeInterval = 100
    var wallMs: Double = 1_700_000_000_000
}

@MainActor
final class ResendRoundTripTests: XCTestCase {

    /// The whole C1 contract, both halves real: a sketch whose write never
    /// completed is re-sent after the next `hello`, the Mac composites it onto
    /// the frame it froze before the drop even though that is a brand new
    /// session, exactly one round reaches the daemon, and the iPad's strokes
    /// survive until that resend's write completes.
    func test_aSketchWhoseWriteFailed_isResentOnceAndUploadedOnce_andTheStrokesSurviveUntilItLands() throws {
        let daemon = FakeDaemon()
        let hub = CanvasHub(daemon: daemon, status: CanvasStatus())
        let wire = Wire()
        let clock = WireClock()
        let model = CanvasModel(receiver: wire,
                                nowMs: { clock.wallMs },
                                uptime: { clock.uptime })

        // A Design Canvas Mac is on the other end, with one frame captured.
        let first = hub.makeSession(deviceName: "Zhao's iPad")
        wire.session = first
        first.canvasPeerDidHello(CanvasPeer(installID: "install-A", deviceKind: "ipad"), outbound: wire)
        first.canvasDidEncodeFrame(
            TestImages.solidBGRAPixelBuffer(width: 40, height: 30, color: TestImages.RGBA(0, 0, 200)),
            captureMs: 1_000
        )

        // Draw Mode: the freeze goes out, the Mac answers, the user draws.
        model.enterDrawMode(zoomRect: .full, viewport: CanvasViewport(width: 40, height: 30, scale: 2))
        let frozen = try XCTUnwrap(wire.take(CanvasWire.frozen), "the Mac answers every freeze")
        model.canvasMessage(type: CanvasWire.frozen, object: frozen)
        XCTAssertEqual(model.drawState, .drawing)
        model.strokesChanged(count: 2)
        guard waitUntil("the frozen frame to be posted as a capture", { daemon.captureCalls.count == 1 }) else { return }

        // Done, into a link that has just gone: the write cannot complete.
        wire.linkUp = false
        let sketch = TestImages.pngData(
            TestImages.rectOnTransparentCGImage(
                width: 40, height: 30,
                rect: CGRect(x: 0, y: 0, width: 40, height: 6),
                fill: TestImages.RGBA(255, 0, 0)
            )
        )
        model.done(sketchPNG: sketch)
        XCTAssertEqual(model.drawState, .retry)
        XCTAssertEqual(model.sendIndicator, .waitingToResend)
        XCTAssertFalse(model.shouldClearStrokes, "the sketch is kept for the resend")
        XCTAssertEqual(wire.annotationWrites, 1)

        // The Mac side notices, and the sender rebuilds the session for the
        // reconnect — a new CanvasSession with an empty ring of its own.
        first.canvasLinkDidDrop()
        let second = hub.makeSession(deviceName: "Zhao's iPad")
        wire.session = second
        wire.linkUp = true
        second.canvasPeerDidHello(CanvasPeer(installID: "install-A", deviceKind: "ipad"), outbound: wire)

        // The new `welcome` is the resend trigger. A later wall clock must not
        // restamp it: it is the same round.
        clock.wallMs += 9_999
        model.welcomeReceived(canvas: true)
        XCTAssertEqual(model.drawState, .sending)
        XCTAssertEqual(wire.annotationWrites, 2, "the same sketch, once more")
        XCTAssertFalse(model.shouldClearStrokes, "still kept: the write has not completed")

        wire.landAnnotationWrite()
        XCTAssertEqual(model.drawState, .live)
        XCTAssertTrue(model.shouldClearStrokes, "cleared only once the resend's write completed")

        guard waitUntil("the resent round to reach the daemon", { daemon.annotationCalls.count == 1 }) else { return }
        let upload = daemon.annotationCalls[0]
        XCTAssertEqual(upload.deviceID, "install-A")
        XCTAssertEqual(upload.sourceCaptureId, "capture-1", "composited onto the frame frozen before the drop")
        XCTAssertEqual(daemon.captureCalls.count, 1, "the frame is posted once, by the session that froze it")
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 2), TestImages.RGBA(255, 0, 0))
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 20), TestImages.RGBA(0, 0, 200))

        // And it stays exactly one round: nothing re-uploads behind the test.
        XCTAssertEqual(daemon.annotationCalls.count, 1)
    }
}
