import XCTest

/// Ported from ai.cst.2 `DesignCanvasDesktopTests/AppModelTests.swift`, plus the new
/// engine-integration cases. Drives poll cycles via injected `probe`/`now`/`childPidProvider`
/// and `pollOnce()` directly — no sleeps, no real daemon/Terminal/AppleScript side effects.
///
/// `startSession()` isn't called here: production `startSession()` requires a real
/// `selectedProject`/`serverEntry` and launches Claude Code via `ClaudeLauncher.launchInTerminal`
/// (AppleScript opening Terminal.app), which is both unavailable in a headless test run and not
/// what these tests are about (they exercise the launch-timeout clock, not the Terminal launch).
/// Since `sessionStarted` is a plain `@Published var`, tests simulate "Start was clicked" by
/// setting it directly; `pollOnce()` stamps its own launch clock on the false->true edge, so this
/// exercises the same timeout logic `startSession()` uses in production (see `AppModel.pollOnce`).

/// Stands in for `OpenDisplaySenderEngine`, which can't be compiled into a hostless bundle (it
/// names `SenderController`/`MacSender`). Records everything the app pushes at it.
@MainActor
final class FakeSenderEngine: SenderEngine {
    var devices: [EngineDevice] = []
    var onDevicesChanged: (() -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var projectNames: [String?] = []
    private(set) var channelStates: [ChannelState] = []

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func setProjectName(_ name: String?) { projectNames.append(name) }
    func setChannelState(_ state: ChannelState) { channelStates.append(state) }

    /// What the real engine does when `SenderController.sessions` changes.
    func publish(_ devices: [EngineDevice]) {
        self.devices = devices
        onDevicesChanged?()
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private final class ProbeBox {
        var result: HealthProbeResult = .refused
    }

    private final class ChildPidBox {
        var pid: Int32?
    }

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

    private func makeModel(childPid: Int32? = 100) -> (model: AppModel, probe: ProbeBox, clock: TestClock, childPid: ChildPidBox) {
        let probeBox = ProbeBox()
        let clock = TestClock()
        let pidBox = ChildPidBox()
        pidBox.pid = childPid
        let model = AppModel(
            probe: { probeBox.result },
            now: clock.now,
            childPidProvider: { pidBox.pid }
        )
        return (model, probeBox, clock, pidBox)
    }

    /// A model wired to a fake engine, for the engine-integration cases below.
    private func makeEngineModel(childPid: Int32? = 100) -> (model: AppModel, probe: ProbeBox, engine: FakeSenderEngine) {
        let probeBox = ProbeBox()
        let pidBox = ChildPidBox()
        pidBox.pid = childPid
        let engine = FakeSenderEngine()
        let model = AppModel(
            probe: { probeBox.result },
            now: Date.init,
            childPidProvider: { pidBox.pid },
            engine: engine
        )
        return (model, probeBox, engine)
    }

    // MARK: - 1. CRITICAL regression: legacy attached payload without sessionStarted must
    // never render as owned. This is the original bug (menu showing "Claude Code attached"
    // for a channel this app run never launched).

    func testLegacyAttachedWithoutSessionStartedIsExistingSessionNeverOwned() async {
        let (model, probe, _, _) = makeModel()
        probe.result = .healthy(health(channelAttached: true))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.display, .existingSessionDetected)
        XCTAssertNotEqual(model.sessionState.display, .ownedAttached)
    }

    // MARK: - 2. Pinning: instanceId change on the same pid drops ownership.

    func testPinnedInstanceMismatchDropsOwnership() async {
        let (model, probe, _, _) = makeModel(childPid: 100)
        probe.result = .healthy(health(pid: 100, instanceId: "A", channelCount: 0))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.daemon, .owned, "first sighting pins the instanceId")

        probe.result = .healthy(health(pid: 100, instanceId: "B", channelCount: 1))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.daemon, .foreign, "different instanceId on the same pid is not us")
        XCTAssertEqual(model.sessionState.display, .existingSessionDetected)
    }

    // MARK: - 3. Child pid change re-pins (owned again with the new identity).

    func testChildPidChangeRePins() async {
        let (model, probe, _, pidBox) = makeModel(childPid: 100)
        probe.result = .healthy(health(pid: 100, instanceId: "A", channelCount: 0))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.daemon, .owned)

        pidBox.pid = 200
        probe.result = .healthy(health(pid: 200, instanceId: "C", channelCount: 0))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.daemon, .owned, "supervisor handing us a new child re-pins automatically")
    }

    // MARK: - 4. canStart gating.

    func testCanStartGating() async {
        let (model, probe, _, _) = makeModel(childPid: 100)
        probe.result = .healthy(health(pid: 100, channelCount: 1))
        await model.pollOnce()
        XCTAssertFalse(model.sessionState.canStart, "a channel is already attached")

        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce()
        XCTAssertTrue(model.sessionState.canStart, "owned daemon, count 0, not started")
    }

    // MARK: - 5. Launch timeout, cleared by attach.

    func testLaunchTimeoutThenClearedByAttach() async {
        let (model, probe, clock, _) = makeModel(childPid: 100)
        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce() // establishes the pin; daemonOnly

        model.sessionStarted = true // simulates "Start" without real Terminal launch
        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.display, .launchPending)

        clock.advance(61)
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.display, .launchTimedOut)

        probe.result = .healthy(health(pid: 100, channelCount: 1))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.display, .ownedAttached, "a channel attaching clears the timeout")
    }

    // MARK: - 6. Auto-clear when the owned channel drops back to 0 — but only after TWO
    // consecutive authoritative zeros. The channel process's SSE stream reconnects (undici's
    // 300 s body timeout closes an idle one), and for the ~0.5 s of that gap the daemon honestly
    // reports zero subscribers. Ending the session on one such poll turned a routine reconnect
    // into "existing session detected", which only Reset clears (I2).

    func testAutoClearsSessionStartedWhenChannelDrops() async {
        let (model, probe, _, _) = makeModel(childPid: 100)
        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce()

        model.sessionStarted = true
        probe.result = .healthy(health(pid: 100, channelCount: 1))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.display, .ownedAttached)
        XCTAssertTrue(model.sessionStarted)

        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce()
        XCTAssertTrue(model.sessionStarted, "one zero could be a channel reconnect in progress")

        await model.pollOnce()
        XCTAssertFalse(model.sessionStarted, "a second zero means the user really quit Claude Code")
        XCTAssertEqual(model.sessionState.display, .daemonOnly)
    }

    func testAChannelReconnectGapDoesNotEndAnOwnedSession() async {
        let (model, probe, _, _) = makeModel(childPid: 100)
        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce()

        model.sessionStarted = true
        probe.result = .healthy(health(pid: 100, channelCount: 1))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.display, .ownedAttached)

        // The gap: the channel's stream is between connections for one poll.
        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce()
        XCTAssertTrue(model.sessionStarted)

        // It reconnects, and the session is back to attached with no Reset.
        probe.result = .healthy(health(pid: 100, channelCount: 1))
        await model.pollOnce()
        XCTAssertTrue(model.sessionStarted)
        XCTAssertEqual(model.sessionState.display, .ownedAttached)

        // And the zero counter started over: one more zero is not two.
        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce()
        XCTAssertTrue(model.sessionStarted, "the run of zeros restarted after the reconnect")
    }

    // MARK: - 6b. Auto-clear requires an AUTHORITATIVE zero: `channelCount()` also reads as 0 for
    // a non-healthy probe (.timedOut/.refused/etc.), so a transient 1.5s probe stall must NOT be
    // read as "the channel dropped to 0" and must never orphan a live, owned+attached session.

    func testTransientProbeStallDoesNotClearOwnedSession() async {
        let (model, probe, _, _) = makeModel(childPid: 100)
        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce()

        model.sessionStarted = true
        probe.result = .healthy(health(pid: 100, channelCount: 1))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.display, .ownedAttached)
        XCTAssertTrue(model.sessionStarted)

        // A transient stall: the probe times out, which reads as an unhealthy/unknown occupant,
        // not an authoritative "channel count is 0" — the session must survive this blip.
        probe.result = .timedOut
        await model.pollOnce()
        XCTAssertTrue(model.sessionStarted, "a probe timeout must never orphan a live session")

        // The daemon answers healthy again with the channel still attached -> back to
        // ownedAttached, proving the session survived the blip rather than having been silently
        // cleared and (coincidentally) never noticed.
        probe.result = .healthy(health(pid: 100, channelCount: 1))
        await model.pollOnce()
        XCTAssertEqual(model.sessionState.display, .ownedAttached, "session survived a transient probe blip")
        XCTAssertTrue(model.sessionStarted)
    }

    // MARK: - 7. startDisabled flips synchronously on sessionStarted, without waiting for a poll.
    // Regression guard for the Start double-invoke race: sessionState.canStart only refreshes on
    // the 2s poll, so a fast double-click must be blocked by the synchronous sessionStarted flag.

    func testStartDisabledFlipsSynchronouslyWithoutPoll() async {
        let (model, probe, _, _) = makeModel(childPid: 100)
        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce()
        XCTAssertTrue(model.sessionState.canStart)
        XCTAssertFalse(model.startDisabled)

        model.sessionStarted = true // what startSession() sets synchronously — NO poll here
        XCTAssertTrue(model.sessionState.canStart, "stale until the next poll — that's the race")
        XCTAssertTrue(model.startDisabled, "gate must flip synchronously, before any poll")
    }

    // MARK: - 8. statusText mapping.

    func testStatusTextMappingMatchesCopy() {
        XCTAssertEqual(DisplayState.ownedAttached.statusText, "\u{25CF} Claude Code attached (this session)")
        XCTAssertEqual(
            DisplayState.existingSessionDetected.statusText,
            "Existing Claude Code session detected \u{2014} not started by this app"
        )
        XCTAssertNotEqual(DisplayState.ownedAttached.statusText, DisplayState.existingSessionDetected.statusText)
        XCTAssertEqual(DisplayState.portOccupiedUnknown.statusText, "Port 47100 is in use by an unknown process")
    }

    // MARK: - 9. resetProcesses() publishes the outcome, restarts the supervisor, and polls
    // immediately (without waiting for the 2s timer, which isn't even running in test
    // construction). `serverEntry` is set to a path guaranteed not to exist, so
    // `restartSupervisor()` — called for real inside `resetProcesses()` — safely no-ops instead
    // of spawning a real node process (see `AppModel.restartSupervisor`'s `FileManager.fileExists`
    // guard). `daemonGaveUp` is used as a witness that restart ran: `restartSupervisor()`
    // unconditionally clears it before its own no-op guard.

    func testResetProcessesPublishesOutcomeRestartsAndPollsImmediately() async {
        let probeBox = ProbeBox()
        probeBox.result = .refused
        let pidBox = ChildPidBox()
        pidBox.pid = 100
        let fakeServerEntry = "/tmp/nonexistent-entry-\(UUID().uuidString).js"
        let fakeQuery = FakeProcessQuery()
        fakeQuery.candidatesToReturn = [ProcessCandidate(pid: 999, command: "node \(fakeServerEntry) --http")]
        let fakeSignaling = FakeProcessSignaling()
        fakeSignaling.aliveSequence[999] = [false]
        let resetService = ProcessResetService(query: fakeQuery, signaling: fakeSignaling, graceAttempts: 1, sleep: { _ in })

        let model = AppModel(
            probe: { probeBox.result },
            now: Date.init,
            childPidProvider: { pidBox.pid },
            resetService: resetService
        )
        model.serverEntry = fakeServerEntry // guaranteed not to exist -> restartSupervisor() safely no-ops
        model.daemonGaveUp = true // sentinel: proves restartSupervisor() ran

        probeBox.result = .healthy(health(pid: 100, instanceId: "A", channelCount: 0))

        await model.resetProcesses()

        XCTAssertEqual(
            model.lastResetOutcome,
            ResetOutcome(killedPids: [999], failedPids: [], refusedUnknownOccupant: false, hadNothingToKill: false)
        )
        XCTAssertFalse(model.daemonGaveUp, "restartSupervisor() unconditionally clears daemonGaveUp")
        XCTAssertEqual(
            model.sessionState.display, .daemonOnly,
            "an immediate pollOnce() inside resetProcesses() picked up the fresh probe result without a manual pollOnce() call"
        )
    }

    // MARK: - 10. startNewAfterReset() reaches canStart and fires the (injected) startSession
    // launch effect exactly once. `launchInTerminal` is injected because the real
    // `ClaudeLauncher.launchInTerminal` opens Terminal.app via AppleScript, which is unsafe in a
    // headless test run (same reasoning `AppModelTests` already documents for why it never calls
    // real `startSession()` elsewhere in this file).

    func testStartNewAfterResetReachesCanStartAndStartsSession() async throws {
        let pidBox = ChildPidBox()
        pidBox.pid = 100
        var pollCount = 0
        let probeSequence: [HealthProbeResult] = [
            .refused, // resetProcesses()'s own immediate pollOnce
            .foreignResponse, // attempt 1: still not ready
            .healthy(health(pid: 100, instanceId: "A", channelCount: 0)), // attempt 2: owned, canStart
        ]
        let fakeQuery = FakeProcessQuery()
        let fakeSignaling = FakeProcessSignaling()
        let resetService = ProcessResetService(query: fakeQuery, signaling: fakeSignaling, graceAttempts: 1, sleep: { _ in })

        var launchedRepoRoots: [URL] = []
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let model = AppModel(
            probe: {
                let result = probeSequence[min(pollCount, probeSequence.count - 1)]
                pollCount += 1
                return result
            },
            now: Date.init,
            childPidProvider: { pidBox.pid },
            resetService: resetService,
            launchInTerminal: { url in
                launchedRepoRoots.append(url)
                return nil
            },
            retryDelay: {}
        )
        model.serverEntry = "/tmp/nonexistent-entry-\(UUID().uuidString).js"
        model.selectedProject = projectDir

        await model.startNewAfterReset()

        XCTAssertEqual(launchedRepoRoots, [projectDir], "canStart was reached, so startSession() should fire the launch effect exactly once")
        XCTAssertTrue(model.sessionStarted)
    }

    // MARK: - 10b. Bounded failure path: canStart never arrives within the attempt bound, so
    // startSession() (and therefore the launch effect) must never fire, and a failure surfaces.

    func testStartNewAfterResetBoundedFailureWhenCanStartNeverArrives() async throws {
        let pidBox = ChildPidBox()
        pidBox.pid = 100
        let fakeQuery = FakeProcessQuery()
        let fakeSignaling = FakeProcessSignaling()
        let resetService = ProcessResetService(query: fakeQuery, signaling: fakeSignaling, graceAttempts: 1, sleep: { _ in })
        var launchCount = 0
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let model = AppModel(
            probe: { .refused }, // daemon never becomes owned -> canStart never true
            now: Date.init,
            childPidProvider: { pidBox.pid },
            resetService: resetService,
            launchInTerminal: { _ in
                launchCount += 1
                return nil
            },
            retryDelay: {}
        )
        model.serverEntry = "/tmp/nonexistent-entry-\(UUID().uuidString).js"
        model.selectedProject = projectDir

        await model.startNewAfterReset()

        XCTAssertEqual(launchCount, 0, "startSession() must never fire when canStart is never reached")
        XCTAssertFalse(model.sessionStarted)
        XCTAssertNotNil(model.configWarning, "a bounded-timeout failure should surface to the menu")
    }

    // MARK: - 10c. If the user clicks "Start session" manually while startNewAfterReset()'s own
    // retry loop is still spinning (e.g. the independent 2s poll loop briefly showed canStart),
    // the retry loop must break out quietly — no second launch, and no stale "reset didn't reach
    // a startable state" warning stomping on a session that's actually starting.

    func testStartNewAfterResetBreaksOutWithoutWarningWhenUserStartsManuallyMidRetry() async throws {
        let pidBox = ChildPidBox()
        pidBox.pid = 100
        let fakeQuery = FakeProcessQuery()
        let fakeSignaling = FakeProcessSignaling()
        let resetService = ProcessResetService(query: fakeQuery, signaling: fakeSignaling, graceAttempts: 1, sleep: { _ in })
        var launchCount = 0
        var retryCount = 0
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        var model: AppModel!
        model = AppModel(
            probe: { .refused }, // this loop's own polls never reach canStart on their own
            now: Date.init,
            childPidProvider: { pidBox.pid },
            resetService: resetService,
            launchInTerminal: { _ in
                launchCount += 1
                return nil
            },
            retryDelay: {
                retryCount += 1
                if retryCount == 1 {
                    // Simulate the manual click: sessionStarted flips true out-of-band, exactly
                    // like startSession() does synchronously.
                    model.sessionStarted = true
                }
            }
        )
        model.serverEntry = "/tmp/nonexistent-entry-\(UUID().uuidString).js"
        model.selectedProject = projectDir

        await model.startNewAfterReset()

        XCTAssertEqual(launchCount, 0, "the manual click already started things directly — startNewAfterReset() must not launch again")
        XCTAssertNil(model.configWarning, "must not post a stale failure warning over a session the user already started")
        XCTAssertTrue(model.sessionStarted)
    }

    // MARK: - Defense in depth: startSession() no-ops if sessionStarted is already true. The menu
    // button is already disabled via `startDisabled` in that case; this guards any other caller.

    func testStartSessionNoOpsWhenAlreadyStarted() async throws {
        let pidBox = ChildPidBox()
        pidBox.pid = 100
        var launchCount = 0
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let model = AppModel(
            probe: { .refused },
            now: Date.init,
            childPidProvider: { pidBox.pid },
            launchInTerminal: { _ in
                launchCount += 1
                return nil
            }
        )
        model.serverEntry = "/tmp/nonexistent-entry-\(UUID().uuidString).js"
        model.selectedProject = projectDir
        model.sessionStarted = true // already started

        model.startSession()

        XCTAssertEqual(launchCount, 0, "startSession() must no-op when sessionStarted is already true")
    }

    // MARK: - isResetting stays true for the WHOLE span of startNewAfterReset(), including while
    // its own retry loop runs after the nested resetProcesses() call has already returned — a
    // plain Bool (rather than a depth counter) would get reset to false by resetProcesses()'s own
    // cleanup mid-flight, briefly re-enabling the reset buttons during an in-flight operation.

    func testIsResettingStaysTrueAcrossStartNewAfterResetsOwnRetryLoop() async throws {
        let pidBox = ChildPidBox()
        pidBox.pid = 100
        let fakeQuery = FakeProcessQuery()
        let fakeSignaling = FakeProcessSignaling()
        let resetService = ProcessResetService(query: fakeQuery, signaling: fakeSignaling, graceAttempts: 1, sleep: { _ in })
        var isResettingDuringRetry: [Bool] = []
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        var model: AppModel!
        model = AppModel(
            probe: { .refused }, // canStart never reached -> retry loop runs to the attempt bound
            now: Date.init,
            childPidProvider: { pidBox.pid },
            resetService: resetService,
            launchInTerminal: { _ in nil },
            retryDelay: { isResettingDuringRetry.append(model.isResetting) }
        )
        model.serverEntry = "/tmp/nonexistent-entry-\(UUID().uuidString).js"
        model.selectedProject = projectDir

        XCTAssertFalse(model.isResetting)
        await model.startNewAfterReset()

        XCTAssertFalse(isResettingDuringRetry.isEmpty)
        XCTAssertTrue(isResettingDuringRetry.allSatisfy { $0 }, "isResetting must stay true through the whole retry loop, not just resetProcesses()'s own nested span")
        XCTAssertFalse(model.isResetting, "isResetting clears once startNewAfterReset() fully completes")
    }

    // MARK: - resetProcesses() clears a stale outcome from a previous run up front, so a lingering
    // "some processes did not stop" line can't be mistaken for this attempt's result while it's
    // still in flight.

    func testResetProcessesClearsStaleOutcomeAtStart() async {
        let probeBox = ProbeBox()
        probeBox.result = .refused
        let pidBox = ChildPidBox()
        pidBox.pid = 100
        let fakeServerEntry = "/tmp/nonexistent-entry-\(UUID().uuidString).js"
        let fakeQuery = FakeProcessQuery()
        let fakeSignaling = FakeProcessSignaling()
        let resetService = ProcessResetService(query: fakeQuery, signaling: fakeSignaling, graceAttempts: 1, sleep: { _ in })

        let model = AppModel(
            probe: { probeBox.result },
            now: Date.init,
            childPidProvider: { pidBox.pid },
            resetService: resetService
        )
        model.serverEntry = fakeServerEntry
        model.lastResetOutcome = ResetOutcome(killedPids: [], failedPids: [999], refusedUnknownOccupant: false, hadNothingToKill: false)

        fakeQuery.candidatesToReturn = [] // this attempt finds nothing to kill
        await model.resetProcesses()

        XCTAssertEqual(
            model.lastResetOutcome,
            ResetOutcome(killedPids: [], failedPids: [], refusedUnknownOccupant: false, hadNothingToKill: true),
            "the stale failedPids from the previous run must not resurface in this attempt's outcome"
        )
    }

    // MARK: - Server-build first guess, used only when the user has never picked one. The
    // selected project is deliberately not a search root: a user's repo is not where this app's
    // own server build lives.

    func testDefaultServerEntryPicksTheFirstRootThatHasTheServerBuild() {
        let roots = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
        let found = AppModel.defaultServerEntry(roots: roots, fileExists: { $0 == "/b/DesignCanvas/server/dist/index.js" })
        XCTAssertEqual(found, "/b/DesignCanvas/server/dist/index.js")
    }

    func testDefaultServerEntryIsNilWhenNoRootHasIt() {
        let roots = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
        XCTAssertNil(
            AppModel.defaultServerEntry(roots: roots, fileExists: { _ in false }),
            "nothing found leaves serverEntry unset, and the menu says \u{201C}Set server build\u{2026}\u{201D}"
        )
    }

    // MARK: - Engine integration (new in Design Canvas)

    func testStartsTheEngineExactlyOnce() {
        let (_, _, engine) = makeEngineModel()
        XCTAssertEqual(engine.startCount, 1, "the engine runs for the app's whole life, started once at launch")
    }

    func testPushesChannelStateAfterEveryPoll() async {
        let (model, probe, engine) = makeEngineModel(childPid: 100)

        probe.result = .healthy(health(pid: 100, channelCount: 1))
        await model.pollOnce()
        probe.result = .healthy(health(pid: 100, channelCount: 0))
        await model.pollOnce()
        probe.result = .refused
        await model.pollOnce()

        XCTAssertEqual(
            engine.channelStates, [.attached, .detached, .none],
            "the iPad's channel row is whatever the last poll saw — a channel, a daemon with none, or no daemon at all"
        )
    }

    func testPushesTheProjectFolderNameOnSelectAndNilWhenCleared() {
        let (model, _, engine) = makeEngineModel()
        XCTAssertEqual(engine.projectNames, [], "nothing is pushed before a project is chosen")

        model.selectRecent(URL(fileURLWithPath: "/Users/me/work/my-app"))
        XCTAssertEqual(engine.projectNames, ["my-app"], "the folder name, not the path")

        model.selectedProject = nil
        XCTAssertEqual(engine.projectNames, ["my-app", nil], "clearing the project clears the iPad's project row")
    }

    func testDeviceListChangesRepublish() {
        let (model, _, engine) = makeEngineModel()
        XCTAssertEqual(model.devices, [])

        let device = EngineDevice(id: "usb:abc", name: "Zhao's iPad", status: "Streaming", onUSB: true)
        engine.publish([device])
        XCTAssertEqual(model.devices, [device])

        engine.publish([])
        XCTAssertEqual(model.devices, [], "a device going away republishes too")
    }
}
