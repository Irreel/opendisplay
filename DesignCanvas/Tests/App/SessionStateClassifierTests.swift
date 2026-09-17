import XCTest

/// Ported from ai.cst.2 `DesignCanvasDesktopTests/SessionStateClassifierTests.swift`.
/// The hostless bundle compiles the sources directly, so there is no
/// `@testable import`; `Health` is now `DaemonHealth` (Task 8), which no longer
/// carries `pairedDevices`/`ipadUrls`.
final class SessionStateClassifierTests: XCTestCase {
    private func health(
        pid: Int? = nil,
        instanceId: String? = nil,
        channelAttached: Bool = false,
        channelCount: Int? = nil
    ) -> DaemonHealth {
        DaemonHealth(
            status: "ok",
            version: "0.0.0",
            channelAttached: channelAttached,
            pid: pid,
            instanceId: instanceId,
            startedAt: nil,
            serverEntry: nil,
            port: 47100,
            channelCount: channelCount,
            channelAttachedAt: nil
        )
    }

    private struct Case {
        let name: String
        let input: SessionStateClassifier.Input
        let daemon: DaemonAxis
        let channel: ChannelAxis
        let display: DisplayState
        let canStart: Bool
        let secondSubscriber: Bool
        let file: StaticString
        let line: UInt
    }

    private func makeCases() -> [Case] {
        [
            Case(
                name: "1. refused -> noDaemon, canStart false",
                input: .init(probe: .refused, supervisedChildPid: nil, pinnedInstanceId: nil, sessionStarted: false, launchTimedOut: false),
                daemon: .none, channel: .none, display: .noDaemon, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "2. healthy owned, count 0, not started -> daemonOnly, canStart TRUE",
                input: .init(probe: .healthy(health(pid: 100, channelCount: 0)), supervisedChildPid: 100, pinnedInstanceId: nil, sessionStarted: false, launchTimedOut: false),
                daemon: .owned, channel: .none, display: .daemonOnly, canStart: true, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "3. healthy owned, count 0, started -> launchPending",
                input: .init(probe: .healthy(health(pid: 100, channelCount: 0)), supervisedChildPid: 100, pinnedInstanceId: nil, sessionStarted: true, launchTimedOut: false),
                daemon: .owned, channel: .launchPending, display: .launchPending, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "4. healthy owned, count 0, started, launchTimedOut -> launchTimedOut",
                input: .init(probe: .healthy(health(pid: 100, channelCount: 0)), supervisedChildPid: 100, pinnedInstanceId: nil, sessionStarted: true, launchTimedOut: true),
                daemon: .owned, channel: .launchPending, display: .launchTimedOut, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "5. healthy owned, count 1, started -> ownedAttached",
                input: .init(probe: .healthy(health(pid: 100, channelCount: 1)), supervisedChildPid: 100, pinnedInstanceId: nil, sessionStarted: true, launchTimedOut: false),
                daemon: .owned, channel: .owned, display: .ownedAttached, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "6. healthy owned, count 1, NOT started -> existingSessionDetected (original bug case)",
                input: .init(probe: .healthy(health(pid: 100, channelCount: 1)), supervisedChildPid: 100, pinnedInstanceId: nil, sessionStarted: false, launchTimedOut: false),
                daemon: .owned, channel: .existing, display: .existingSessionDetected, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "7. healthy, pid mismatch, count 1 -> daemon foreign, existingSessionDetected",
                input: .init(probe: .healthy(health(pid: 200, channelCount: 1)), supervisedChildPid: 100, pinnedInstanceId: nil, sessionStarted: true, launchTimedOut: false),
                daemon: .foreign, channel: .existing, display: .existingSessionDetected, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "8. healthy, pid matches but pinnedInstanceId differs -> foreign",
                input: .init(probe: .healthy(health(pid: 100, instanceId: "xyz", channelCount: 0)), supervisedChildPid: 100, pinnedInstanceId: "abc", sessionStarted: false, launchTimedOut: false),
                daemon: .foreign, channel: .none, display: .foreignDaemon, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "9. legacy shape (pid nil, channelAttached true, channelCount nil) -> foreign + existingSessionDetected via fallback count",
                input: .init(probe: .healthy(health(pid: nil, channelAttached: true, channelCount: nil)), supervisedChildPid: 100, pinnedInstanceId: nil, sessionStarted: false, launchTimedOut: false),
                daemon: .foreign, channel: .existing, display: .existingSessionDetected, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "10. legacy shape, channelAttached false -> foreignDaemon",
                input: .init(probe: .healthy(health(pid: nil, channelAttached: false, channelCount: nil)), supervisedChildPid: 100, pinnedInstanceId: nil, sessionStarted: false, launchTimedOut: false),
                daemon: .foreign, channel: .none, display: .foreignDaemon, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "11. foreignResponse -> portOccupiedUnknown",
                input: .init(probe: .foreignResponse, supervisedChildPid: nil, pinnedInstanceId: nil, sessionStarted: false, launchTimedOut: false),
                daemon: .unknownOccupant, channel: .none, display: .portOccupiedUnknown, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "12. timedOut -> portOccupiedUnknown",
                input: .init(probe: .timedOut, supervisedChildPid: nil, pinnedInstanceId: nil, sessionStarted: false, launchTimedOut: false),
                daemon: .unknownOccupant, channel: .none, display: .portOccupiedUnknown, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "13. badStatus(500) -> portOccupiedUnknown",
                input: .init(probe: .badStatus(500), supervisedChildPid: nil, pinnedInstanceId: nil, sessionStarted: false, launchTimedOut: false),
                daemon: .unknownOccupant, channel: .none, display: .portOccupiedUnknown, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "14. healthy owned, count 2, started -> ownedAttached with secondSubscriber true",
                input: .init(probe: .healthy(health(pid: 100, channelCount: 2)), supervisedChildPid: 100, pinnedInstanceId: nil, sessionStarted: true, launchTimedOut: false),
                daemon: .owned, channel: .owned, display: .ownedAttached, canStart: false, secondSubscriber: true,
                file: #filePath, line: #line
            ),
            Case(
                name: "15. healthy foreign (supervisedChildPid nil), count 1 -> existingSessionDetected",
                input: .init(probe: .healthy(health(pid: 100, channelCount: 1)), supervisedChildPid: nil, pinnedInstanceId: nil, sessionStarted: false, launchTimedOut: false),
                daemon: .foreign, channel: .existing, display: .existingSessionDetected, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
            Case(
                name: "16. healthy owned, count 1, started, canStart false (already attached)",
                input: .init(probe: .healthy(health(pid: 100, instanceId: "abc", channelCount: 1)), supervisedChildPid: 100, pinnedInstanceId: "abc", sessionStarted: true, launchTimedOut: false),
                daemon: .owned, channel: .owned, display: .ownedAttached, canStart: false, secondSubscriber: false,
                file: #filePath, line: #line
            ),
        ]
    }

    func testDecisionTable() {
        for c in makeCases() {
            let result = SessionStateClassifier.classify(c.input)
            XCTAssertEqual(result.daemon, c.daemon, "\(c.name): daemon", file: c.file, line: c.line)
            XCTAssertEqual(result.channel, c.channel, "\(c.name): channel", file: c.file, line: c.line)
            XCTAssertEqual(result.display, c.display, "\(c.name): display", file: c.file, line: c.line)
            XCTAssertEqual(result.canStart, c.canStart, "\(c.name): canStart", file: c.file, line: c.line)
            XCTAssertEqual(result.secondSubscriber, c.secondSubscriber, "\(c.name): secondSubscriber", file: c.file, line: c.line)
        }
    }
}
