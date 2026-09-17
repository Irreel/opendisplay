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
