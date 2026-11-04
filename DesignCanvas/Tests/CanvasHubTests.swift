import Foundation
import XCTest

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine and
// DesignCanvas/Shared straight into it (see project.yml), so everything under
// test is available without an import.

@MainActor
final class CanvasHubTests: XCTestCase {

    private let frames = FakeFrames()

    private func round(_ id: String) -> CanvasRound {
        CanvasRound(
            annotationId: id,
            createdAt: "2026-09-16T12:00:00.000Z",
            status: .applied,
            message: nil,
            prUrl: nil,
            note: nil
        )
    }

    private func replyIDs(_ outbound: FakeOutbound) -> [String] {
        outbound.objects(ofType: CanvasWire.agentReply).compactMap { $0["annotationId"] as? String }
    }

    private func makeHub(_ daemon: FakeDaemon, status: CanvasStatus = CanvasStatus()) -> CanvasHub {
        CanvasHub(daemon: daemon, status: status, frames: frames)
    }

    /// The session for one iPad, attached to `outbound` as its hello would.
    @discardableResult
    private func session(
        _ hub: CanvasHub,
        deviceName: String,
        installID: String,
        outbound: FakeOutbound
    ) -> CanvasSession {
        let session = hub.store.session(installID: installID, deviceName: deviceName)
        session.attach(outbound)
        return session
    }

    func test_anUpdateReachesOnlyTheSessionWhoseDeviceItNames() {
        let daemon = FakeDaemon()
        let hub = makeHub(daemon)
        let outboundA = FakeOutbound()
        let outboundB = FakeOutbound()
        session(hub, deviceName: "iPad A", installID: "install-A", outbound: outboundA)
        session(hub, deviceName: "iPad B", installID: "install-B", outbound: outboundB)
        hub.start()
        defer { hub.stop() }

        daemon.emit(RoundUpdate(deviceID: "install-A", round: round("a1")))

        guard waitUntil("A to be told about its round", { replyIDs(outboundA) == ["a1"] }) else { return }
        XCTAssertEqual(replyIDs(outboundB), [])
    }

    /// C1: one session per iPad for the app's life, so the reconnect after a
    /// link drop — however late — finds the frame it froze and the round it
    /// was sending.
    func test_theStoreHandsBackTheSameSessionForTheSameInstallID() {
        let hub = makeHub(FakeDaemon())

        let first = hub.store.session(installID: "install-A", deviceName: "iPad A")
        let again = hub.store.session(installID: "install-A", deviceName: "renamed")
        let other = hub.store.session(installID: "install-B", deviceName: "iPad B")

        XCTAssertTrue(first === again)
        XCTAssertFalse(first === other)
        XCTAssertEqual(hub.store.all.count, 2)
    }

    func test_aReconnectThroughTheStoreFinishesTheFrozenRound() {
        let daemon = FakeDaemon()
        let hub = makeHub(daemon)
        let outbound = FakeOutbound()
        let first = session(hub, deviceName: "iPad A", installID: "install-A", outbound: outbound)
        frames.put(TestImages.solidBGRAPixelBuffer(width: 16, height: 12, color: TestImages.RGBA(0, 0, 200)), frame: 1)
        first.receive(type: CanvasWire.freeze, object: FreezeMessage(frame: 1, t: 1_700_000_000_000).json,
                      attachment: Data())
        guard waitUntil("the frozen frame to be posted", { daemon.captureCalls.count == 1 }) else { return }
        first.detach(outbound)

        let reconnected = FakeOutbound()
        let second = session(hub, deviceName: "iPad A", installID: "install-A", outbound: reconnected)
        let sketch = TestImages.pngData(TestImages.solidCGImage(width: 16, height: 12,
                                                                color: TestImages.RGBA(0, 0, 0), hasAlpha: true))
        let annotation = AnnotationMessage(sketchPNG: sketch, viewport: CanvasViewport(width: 16, height: 12, scale: 2),
                                           note: nil, t: 1_700_000_001_000)
        second.receive(type: CanvasWire.annotation, object: annotation.json, attachment: sketch)

        guard waitUntil("the resent annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-1")
        XCTAssertEqual(daemon.captureCalls.count, 1)
    }

    /// I2: the rounds stream reconnects (an idle timeout, a daemon restart),
    /// and the daemon replays nothing — so every connection is followed by a
    /// fresh snapshot for each connected device.
    func test_aConnectedRoundsStream_resendsEverySessionsSnapshot() {
        let daemon = FakeDaemon()
        let hub = makeHub(daemon)
        let outboundA = FakeOutbound()
        let outboundB = FakeOutbound()
        session(hub, deviceName: "iPad A", installID: "install-A", outbound: outboundA)
        session(hub, deviceName: "iPad B", installID: "install-B", outbound: outboundB)
        guard waitUntil("both hellos' snapshots", {
            outboundA.objects(ofType: CanvasWire.rounds).count == 1
                && outboundB.objects(ofType: CanvasWire.rounds).count == 1
        }) else { return }

        hub.start()
        defer { hub.stop() }

        guard waitUntil("both devices to be re-sent their snapshot", {
            outboundA.objects(ofType: CanvasWire.rounds).count == 2
                && outboundB.objects(ofType: CanvasWire.rounds).count == 2
        }) else { return }
    }

    /// P1: the channel state reaches every connected iPad when it changes,
    /// and only then — the app sets it on every 2 s health poll.
    func test_setChannelState_tellsEveryIPad_onlyOnAChange() {
        let status = CanvasStatus()
        let hub = makeHub(FakeDaemon(), status: status)
        let outboundA = FakeOutbound()
        let outboundB = FakeOutbound()
        session(hub, deviceName: "iPad A", installID: "install-A", outbound: outboundA)
        session(hub, deviceName: "iPad B", installID: "install-B", outbound: outboundB)

        hub.setChannelState(.attached)
        hub.setChannelState(.attached)

        for outbound in [outboundA, outboundB] {
            XCTAssertEqual(outbound.objects(ofType: CanvasWire.status).compactMap(StatusMessage.init(json:)),
                           [StatusMessage(channel: .none, project: nil), StatusMessage(channel: .attached, project: nil)])
        }
        XCTAssertEqual(status.channelState, .attached)
    }

    /// I3: the menu tells the user how many sketches are still waiting for the
    /// daemon, which means the count has to add up across every device.
    func test_pendingUploads_sumsWhatEverySessionStillOwes() {
        let daemon = FakeDaemon()
        daemon.setAnnotationsAlwaysFail(true)
        let hub = makeHub(daemon)
        XCTAssertEqual(hub.pendingUploads, 0)

        let outboundA = FakeOutbound()
        let outboundB = FakeOutbound()
        let sessionA = session(hub, deviceName: "iPad A", installID: "install-A", outbound: outboundA)
        let sessionB = session(hub, deviceName: "iPad B", installID: "install-B", outbound: outboundB)
        queueAnnotation(on: sessionA, frame: 1)
        queueAnnotation(on: sessionB, frame: 2)

        XCTAssertEqual(hub.pendingUploads, 2)

        daemon.setAnnotationsAlwaysFail(false)
        waitUntil("both queues to drain") { hub.pendingUploads == 0 }
    }

    /// Freezes one frame and sends a sketch for it, leaving one upload pending.
    private func queueAnnotation(on session: CanvasSession, frame: UInt64) {
        frames.put(TestImages.solidBGRAPixelBuffer(width: 8, height: 6, color: TestImages.RGBA(0, 0, 200)), frame: frame)
        session.receive(type: CanvasWire.freeze, object: FreezeMessage(frame: frame, t: 1).json, attachment: Data())
        let sketch = TestImages.pngData(TestImages.solidCGImage(width: 8, height: 6,
                                                                color: TestImages.RGBA(0, 0, 0), hasAlpha: true))
        let annotation = AnnotationMessage(sketchPNG: sketch, viewport: CanvasViewport(width: 8, height: 6, scale: 2),
                                           note: nil, t: Double(frame))
        session.receive(type: CanvasWire.annotation, object: annotation.json, attachment: sketch)
    }

    func test_stop_endsConsumptionOfTheDaemonStream() {
        let daemon = FakeDaemon()
        let terminated = expectation(description: "the round-updates stream terminated")
        daemon.onUpdatesTerminated = { terminated.fulfill() }
        let hub = makeHub(daemon)
        let outbound = FakeOutbound()
        session(hub, deviceName: "iPad A", installID: "install-A", outbound: outbound)
        hub.start()

        daemon.emit(RoundUpdate(deviceID: "install-A", round: round("a1")))
        guard waitUntil("the first update to arrive", { replyIDs(outbound) == ["a1"] }) else { return }

        hub.stop()
        wait(for: [terminated], timeout: 5)

        // Consumption has provably ended, so this one can reach nobody.
        daemon.emit(RoundUpdate(deviceID: "install-A", round: round("a2")))
        XCTAssertEqual(replyIDs(outbound), ["a1"])
    }
}
