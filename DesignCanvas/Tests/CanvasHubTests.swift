import Foundation
import XCTest

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine,
// DesignCanvas/Shared and Mac/SenderCanvasHooks.swift straight into it (see
// project.yml), so everything under test is available without an import.

@MainActor
final class CanvasHubTests: XCTestCase {

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

    @discardableResult
    private func session(
        _ hub: CanvasHub,
        deviceName: String,
        installID: String,
        outbound: FakeOutbound
    ) -> CanvasSession {
        let session = hub.makeSession(deviceName: deviceName)
        session.canvasPeerDidHello(CanvasPeer(installID: installID, deviceKind: "ipad"), outbound: outbound)
        return session
    }

    func test_anUpdateReachesOnlyTheSessionWhoseDeviceItNames() {
        let daemon = FakeDaemon()
        let hub = CanvasHub(daemon: daemon, status: CanvasStatus())
        let outboundA = FakeOutbound()
        let outboundB = FakeOutbound()
        let sessionA = session(hub, deviceName: "iPad A", installID: "install-A", outbound: outboundA)
        let sessionB = session(hub, deviceName: "iPad B", installID: "install-B", outbound: outboundB)
        hub.start()
        defer { hub.stop() }

        daemon.emit(RoundUpdate(deviceID: "install-A", round: round("a1")))

        guard waitUntil("A to be told about its round", { replyIDs(outboundA) == ["a1"] }) else { return }
        XCTAssertEqual(replyIDs(outboundB), [])
        XCTAssertNotNil(sessionA)
        XCTAssertNotNil(sessionB)
    }

    func test_aDeallocatedSessionIsPruned_andTheLiveOneStillGetsItsUpdates() {
        let daemon = FakeDaemon()
        let hub = CanvasHub(daemon: daemon, status: CanvasStatus())
        let outbound = FakeOutbound()
        let kept = session(hub, deviceName: "kept", installID: "install-A", outbound: outbound)

        var temporary: CanvasSession? = hub.makeSession(deviceName: "temporary")
        XCTAssertNotNil(temporary)
        XCTAssertEqual(hub.sessionCount, 2)

        temporary = nil
        XCTAssertEqual(hub.sessionCount, 1)

        hub.start()
        defer { hub.stop() }
        daemon.emit(RoundUpdate(deviceID: "install-A", round: round("a1")))
        guard waitUntil("the surviving session to be told", { replyIDs(outbound) == ["a1"] }) else { return }
        XCTAssertNotNil(kept)
    }

    /// C1: the hub is the one thing that outlives the session a link drop
    /// kills, so it is where a frozen frame waits for the sketch the iPad will
    /// re-send after the reconnect.
    func test_aReplacementSessionFromTheHubInheritsTheParkedFreezeCapture() {
        let daemon = FakeDaemon()
        let hub = CanvasHub(daemon: daemon, status: CanvasStatus())
        let outbound = FakeOutbound()
        let first = hub.makeSession(deviceName: "iPad A")
        first.canvasPeerDidHello(CanvasPeer(installID: "install-A", deviceKind: "ipad"), outbound: outbound)
        first.canvasDidEncodeFrame(
            TestImages.solidBGRAPixelBuffer(width: 16, height: 12, color: TestImages.RGBA(0, 0, 200)),
            captureMs: 1_000
        )
        var freeze = FreezeMessage(captureMs: 1_000, zoomRect: .full, t: 1_700_000_000_000).json
        freeze["type"] = CanvasWire.freeze
        first.canvasDidReceive(type: CanvasWire.freeze, object: freeze, outbound: outbound)
        guard waitUntil("the frozen frame to be posted", { daemon.captureCalls.count == 1 }) else { return }
        first.canvasLinkDidDrop()

        let second = hub.makeSession(deviceName: "iPad A")
        let secondOutbound = FakeOutbound()
        second.canvasPeerDidHello(CanvasPeer(installID: "install-A", deviceKind: "ipad"), outbound: secondOutbound)
        var annotation = AnnotationMessage(
            sketchPNG: Data(),
            zoomRect: .full,
            viewport: CanvasViewport(width: 16, height: 12, scale: 2),
            note: nil,
            t: 1_700_000_001_000
        ).json
        annotation["type"] = CanvasWire.annotation
        second.canvasDidReceive(type: CanvasWire.annotation, object: annotation, outbound: secondOutbound)

        guard waitUntil("the resent annotation to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(daemon.annotationCalls[0].sourceCaptureId, "capture-1")
        XCTAssertEqual(daemon.captureCalls.count, 1)
    }

    func test_stop_endsConsumptionOfTheDaemonStream() {
        let daemon = FakeDaemon()
        let terminated = expectation(description: "the round-updates stream terminated")
        daemon.onUpdatesTerminated = { terminated.fulfill() }
        let hub = CanvasHub(daemon: daemon, status: CanvasStatus())
        let outbound = FakeOutbound()
        // Held for the whole test: the hub registers sessions weakly.
        let device = session(hub, deviceName: "iPad A", installID: "install-A", outbound: outbound)
        hub.start()

        daemon.emit(RoundUpdate(deviceID: "install-A", round: round("a1")))
        guard waitUntil("the first update to arrive", { replyIDs(outbound) == ["a1"] }) else { return }

        hub.stop()
        wait(for: [terminated], timeout: 5)

        // Consumption has provably ended, so this one can reach nobody.
        daemon.emit(RoundUpdate(deviceID: "install-A", round: round("a2")))
        XCTAssertEqual(replyIDs(outbound), ["a1"])
        XCTAssertNotNil(device)
    }
}
