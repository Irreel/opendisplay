import XCTest

/// From ai.cst.2 `DesignCanvasDesktopTests/SessionStateClassifierTests.swift`, rewritten for
/// sessions that connect through the Claude Code mod: the daemon axis (ADR-0004) is tested as
/// before; the other axis no longer asks who started a session, only whether one is connected
/// or a launch is still on its way (X9).
final class SessionStateClassifierTests: XCTestCase {
    private func health(
        pid: Int? = nil,
        instanceId: String? = nil,
        channelCount: Int? = nil,
        sessionCount: Int? = nil
    ) -> DaemonHealth {
        DaemonHealth(
            status: "ok", version: "0.0.0", channelAttached: (channelCount ?? 0) > 0, pid: pid,
            instanceId: instanceId, startedAt: nil, serverEntry: nil, port: 47100,
            channelCount: channelCount, channelAttachedAt: nil, sessionCount: sessionCount
        )
    }

    private func classify(
        _ probe: HealthProbeResult, childPid: Int32? = 100, pinned: String? = nil,
        started: Bool = false, timedOut: Bool = false
    ) -> SessionState {
        SessionStateClassifier.classify(.init(
            probe: probe, supervisedChildPid: childPid, pinnedInstanceId: pinned,
            sessionStarted: started, launchTimedOut: timedOut
        ))
    }

    private func assertState(
        _ state: SessionState, _ daemon: DaemonAxis, _ channel: ChannelAxis, _ display: DisplayState,
        canStart: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(state.daemon, daemon, message, file: file, line: line)
        XCTAssertEqual(state.channel, channel, message, file: file, line: line)
        XCTAssertEqual(state.display, display, message, file: file, line: line)
        XCTAssertEqual(state.canStart, canStart, message, file: file, line: line)
    }

    // MARK: - Daemon axis (unchanged rules)

    func testNoDaemonAndUnknownOccupants() {
        assertState(classify(.refused), .none, .none, .noDaemon, canStart: false, "nothing listening")
        for probe in [HealthProbeResult.timedOut, .badStatus(500), .foreignResponse] {
            assertState(classify(probe, started: true), .unknownOccupant, .none, .portOccupiedUnknown,
                        canStart: false, "\(probe): something else holds the port")
        }
    }

    func testADaemonThisAppDidNotSpawnIsForeign() {
        assertState(classify(.healthy(health(pid: nil))), .foreign, .none, .foreignDaemon, canStart: false, "legacy daemon, no pid")
        assertState(classify(.healthy(health(pid: 999))), .foreign, .none, .foreignDaemon, canStart: false, "another pid")
        assertState(classify(.healthy(health(pid: 100)), childPid: nil), .foreign, .none, .foreignDaemon, canStart: false, "no supervised child")
        assertState(classify(.healthy(health(pid: 100, instanceId: "B")), pinned: "A"), .foreign, .none, .foreignDaemon,
                    canStart: false, "same pid, different instance: a pid reused by someone else")
        assertState(classify(.healthy(health(pid: 100, instanceId: "A")), pinned: "A"), .owned, .none, .daemonOnly,
                    canStart: true, "pinned instance matches")
    }

    // MARK: - Session axis

    func testOwnedDaemonWithNoSession() {
        assertState(classify(.healthy(health(pid: 100, sessionCount: 0))), .owned, .none, .daemonOnly, canStart: true, "idle")
        assertState(classify(.healthy(health(pid: 100))), .owned, .none, .daemonOnly, canStart: true,
                    "a daemon that reports no sessionCount has none")
    }

    func testALaunchOnItsWayHoldsStartUntilItArrivesOrTimesOut() {
        assertState(classify(.healthy(health(pid: 100, sessionCount: 0)), started: true), .owned, .launchPending, .launchPending,
                    canStart: false, "launched, not registered yet")
        assertState(classify(.healthy(health(pid: 100, sessionCount: 0)), started: true, timedOut: true), .owned, .launchPending,
                    .launchTimedOut, canStart: false, "60 s on")
    }

    func testAnySessionIsConnectedWhoeverStartedIt() {
        // X9: started by hand, or before this app was relaunched, a session with the mod is usable.
        assertState(classify(.healthy(health(pid: 100, sessionCount: 1))), .owned, .connected, .ownedAttached,
                    canStart: true, "connected, and another can be started beside it")
        assertState(classify(.healthy(health(pid: 100, sessionCount: 3))), .owned, .connected, .ownedAttached,
                    canStart: true, "several sessions are one state, not a warning")
        assertState(classify(.healthy(health(pid: 100, sessionCount: 1)), started: true), .owned, .connected, .ownedAttached,
                    canStart: false, "connected while a second launch is still on its way")
    }

    func testAChannelIsNotASession() {
        // The old channel process may still be attached during the changeover. It carries no
        // sketches for this app any more and must not read as a connection.
        assertState(classify(.healthy(health(pid: 100, channelCount: 1, sessionCount: 0))), .owned, .none, .daemonOnly,
                    canStart: true, "channel attached, no session")
        assertState(classify(.healthy(health(pid: 100, channelCount: 2))), .owned, .none, .daemonOnly, canStart: true, "legacy payload")
    }

    func testSessionsOnAForeignDaemonAreNotOurs() {
        assertState(classify(.healthy(health(pid: 999, sessionCount: 2))), .foreign, .connected, .existingSessionDetected,
                    canStart: false, "another instance has the sessions")
        assertState(classify(.healthy(health(pid: 999, sessionCount: 0)), started: true), .foreign, .launchPending, .foreignDaemon,
                    canStart: false, "a launch cannot arrive at a daemon that is not ours")
    }

    // MARK: - What the iPad is told

    func testChannelStateForTheIPad() {
        XCTAssertEqual(ChannelState(session: classify(.refused)), ChannelState.none)
        XCTAssertEqual(ChannelState(session: classify(.timedOut)), ChannelState.none)
        XCTAssertEqual(ChannelState(session: classify(.healthy(health(pid: 100, sessionCount: 0)))), .detached)
        XCTAssertEqual(ChannelState(session: classify(.healthy(health(pid: 100, sessionCount: 0)), started: true)), .detached)
        XCTAssertEqual(ChannelState(session: classify(.healthy(health(pid: 100, sessionCount: 1)))), .attached)
        XCTAssertEqual(ChannelState(session: classify(.healthy(health(pid: 999, sessionCount: 1)))), .detached,
                       "sessions this Mac app cannot reach are not attached, and `existing` is no longer sent")
    }
}
