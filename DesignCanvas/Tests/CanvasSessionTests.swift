import Foundation
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
        now: @escaping () -> Date = Date.init
    ) -> CanvasSession {
        CanvasSession(
            deviceName: deviceName,
            daemon: daemon,
            status: status,
            workQueue: DispatchQueue(label: "test.canvas.work", qos: .utility),
            now: now,
            sleep: { _ in }
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

        waitUntil("the freeze capture to be posted") { daemon.captureCalls.count == 1 }
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
        waitUntil("the hitting freeze's capture to be posted") { daemon.captureCalls.count == 1 }
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
}
