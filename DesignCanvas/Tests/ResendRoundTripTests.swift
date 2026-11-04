import CoreGraphics
import Foundation
import XCTest

// NOTE: this hostless bundle compiles DesignCanvas/iOS/Logic,
// DesignCanvas/Mac/Engine and DesignCanvas/Shared straight into it (see
// project.yml), so both halves of the round — the iPad's `CanvasModel` and the
// Mac's `CanvasSession`/`CanvasHub` — are available here without an import.
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
/// real `CanvasReceiver`/`MirrorLink` pair would. What the session writes back
/// is recorded rather than delivered, and the test pumps it into the model —
/// explicitly, so the ordering of a nested effect is visible in the test
/// rather than buried in a queue hop.
private final class Wire: CanvasReceiving, CanvasOutbound {
    var isConnected = true
    var frame: UInt64? = 1

    /// The Mac-side session this iPad is currently connected to, nil while the
    /// link is down.
    var session: CanvasSession?
    /// While false a write never reaches the Mac and its completion answers
    /// false — which is all "the link went down mid-send" means (ruling 5).
    var linkUp = true

    private(set) var annotationWrites = 0
    private(set) var inbound: [[String: Any]] = []
    private var heldAnnotationCompletion: ((Bool) -> Void)?

    // MARK: - CanvasReceiving

    func currentFrame() -> UInt64? { frame }

    func setFrozen(_ frozen: Bool) {}

    func send(_ type: String, _ object: [String: Any], attachment: Data,
              completion: @escaping (Bool) -> Void) {
        if type == CanvasWire.annotation { annotationWrites += 1 }
        guard linkUp, let session else {
            completion(false)
            return
        }
        session.receive(type: type, object: object, attachment: attachment)
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
    func send(_ type: String, _ object: [String: Any], attachment: Data) -> Bool {
        guard WireCodec.message(type, object, attachment: attachment) != nil else { return false }
        var message = object
        message["type"] = type
        inbound.append(message)
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
    /// the frame it froze before the drop even though it arrives on a new
    /// link, exactly one round reaches the daemon, and the iPad's strokes
    /// survive until that resend's write completes.
    func test_aSketchWhoseWriteFailed_isResentOnceAndUploadedOnce_andTheStrokesSurviveUntilItLands() throws {
        let daemon = FakeDaemon()
        let frames = FakeFrames()
        let hub = CanvasHub(daemon: daemon, status: CanvasStatus(), frames: frames)
        let wire = Wire()
        let clock = WireClock()
        let model = CanvasModel(receiver: wire,
                                nowMs: { clock.wallMs },
                                uptime: { clock.uptime })

        // A Mac is on the other end, with the frame on screen in its ring.
        let first = hub.store.session(installID: "install-A", deviceName: "Zhao's iPad")
        wire.session = first
        first.attach(wire)
        frames.put(TestImages.solidBGRAPixelBuffer(width: 40, height: 30, color: TestImages.RGBA(0, 0, 200)),
                   frame: 1)

        // Draw Mode: the freeze goes out, the Mac answers, the user draws.
        model.enterDrawMode(viewport: CanvasViewport(width: 40, height: 30, scale: 2))
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

        // The Mac side notices the drop, and the iPad's hello on the next link
        // finds its session through the store, where it waited.
        first.detach(wire)
        let second = hub.store.session(installID: "install-A", deviceName: "Zhao's iPad")
        XCTAssertTrue(second === first, "one session per iPad, across links")
        wire.session = second
        wire.linkUp = true
        second.attach(wire)

        // The Mac's hello is the resend trigger. A later wall clock must not
        // restamp it: it is the same round.
        clock.wallMs += 9_999
        model.macHelloReceived(name: "Studio Mac")
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
        XCTAssertEqual(daemon.captureCalls.count, 1, "the frame is posted once, by the freeze")
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 2), TestImages.RGBA(255, 0, 0))
        XCTAssertEqual(TestImages.pixel(inPNG: upload.compositePNG, x: 5, y: 20), TestImages.RGBA(0, 0, 200))

        // And it stays exactly one round: nothing re-uploads behind the test.
        XCTAssertEqual(daemon.annotationCalls.count, 1)
    }
}
