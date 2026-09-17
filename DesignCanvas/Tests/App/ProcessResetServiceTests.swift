import XCTest

/// Ported from ai.cst.2 `DesignCanvasDesktopTests/ProcessResetServiceTests.swift`.
///
/// Fake query/signaler record every call so tests can assert exactly which pids were signaled —
/// never a real process. Not marked `private`/`fileprivate` so `AppModelTests` can reuse them
/// (same convention as `FakeRunner`/`TestClock` in `DaemonSupervisorTests.swift`).
final class FakeProcessQuery: ProcessQuerying {
    var candidatesToReturn: [ProcessCandidate] = []
    /// Optional per-`serverEntry` overrides — tests exercising the second reset source (a
    /// health-reported `serverEntry` different from the configured one) need distinct candidate
    /// sets per queried path; any path not present here falls back to `candidatesToReturn`.
    var candidatesByServerEntry: [String: [ProcessCandidate]] = [:]
    var errorToThrow: Error?
    private(set) var queriedServerEntries: [String] = []

    func candidates(matching serverEntry: String) throws -> [ProcessCandidate] {
        queriedServerEntries.append(serverEntry)
        if let errorToThrow { throw errorToThrow }
        return candidatesByServerEntry[serverEntry] ?? candidatesToReturn
    }
}

final class FakeProcessSignaling: ProcessSignaling {
    private(set) var terminatedPids: [Int32] = []
    var terminateResult: (Int32) -> Bool = { _ in true }
    /// Per-pid sequence of `isAlive` answers, consumed in order; once exhausted the last value
    /// repeats. Defaults to "already dead" for any pid a test doesn't configure.
    var aliveSequence: [Int32: [Bool]] = [:]
    private var aliveCallIndex: [Int32: Int] = [:]

    func terminate(pid: Int32) -> Bool {
        terminatedPids.append(pid)
        return terminateResult(pid)
    }

    func isAlive(pid: Int32) -> Bool {
        guard let sequence = aliveSequence[pid], !sequence.isEmpty else { return false }
        let index = min(aliveCallIndex[pid] ?? 0, sequence.count - 1)
        aliveCallIndex[pid] = index + 1
        return sequence[index]
    }
}

final class ProcessResetServiceTests: XCTestCase {
    private let serverEntry = "/srv/design-canvas/dist/index.js"

    private func makeService(query: FakeProcessQuery, signaling: FakeProcessSignaling, graceAttempts: Int = 1) -> ProcessResetService {
        ProcessResetService(query: query, signaling: signaling, graceAttempts: graceAttempts, sleep: { _ in })
    }

    // MARK: - 1. Mixed candidates: only the argv-verified pid is ever signaled.

    func testMixedCandidatesOnlyMatchingArgvIsSignaled() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [
            ProcessCandidate(pid: 111, command: "/opt/homebrew/bin/node \(serverEntry) --http"),
            ProcessCandidate(pid: 222, command: "/usr/bin/some-other-daemon --unrelated"),
        ]
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[111] = [false]
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertEqual(outcome.killedPids, [111])
        XCTAssertEqual(signaling.terminatedPids, [111], "non-matching command must never be signaled")
        XCTAssertFalse(outcome.refusedUnknownOccupant)
        XCTAssertFalse(outcome.hadNothingToKill)
    }

    // MARK: - 2. The app's own supervised child pid is excluded, never signaled.

    func testOwnChildPidIsExcludedAndNeverSignaled() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [
            ProcessCandidate(pid: 100, command: "node \(serverEntry) --http"),
            ProcessCandidate(pid: 200, command: "node \(serverEntry) --channel"),
        ]
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[200] = [false]
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: 100)

        XCTAssertFalse(signaling.terminatedPids.contains(100), "the supervisor owns the app's own child; reset must not signal it")
        XCTAssertEqual(outcome.killedPids, [200])
    }

    // MARK: - 3. Unknown port occupant: refused (and reported), but verified helpers are still killed.

    func testUnknownOccupantIsRefusedButVerifiedHelpersStillKilled() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [ProcessCandidate(pid: 300, command: "node \(serverEntry) --http")]
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[300] = [false]
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .foreignResponse, ownChildPid: nil)

        XCTAssertTrue(outcome.refusedUnknownOccupant)
        XCTAssertEqual(outcome.killedPids, [300])
    }

    func testUnknownOccupantCoversTimedOutAndBadStatus() {
        let query = FakeProcessQuery()
        let signaling = FakeProcessSignaling()
        let service = makeService(query: query, signaling: signaling)

        XCTAssertTrue(service.reset(serverEntry: serverEntry, lastProbe: .timedOut, ownChildPid: nil).refusedUnknownOccupant)
        XCTAssertTrue(service.reset(serverEntry: serverEntry, lastProbe: .badStatus(500), ownChildPid: nil).refusedUnknownOccupant)
    }

    // MARK: - 4. Signal failure is recorded as failed; other candidates are still processed.

    func testSignalFailureRecordedAsFailedOthersStillProcessed() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [
            ProcessCandidate(pid: 400, command: "node \(serverEntry) --http"),
            ProcessCandidate(pid: 401, command: "node \(serverEntry) --channel"),
        ]
        let signaling = FakeProcessSignaling()
        signaling.terminateResult = { pid in pid != 400 } // 400 fails to signal (e.g. EPERM)
        signaling.aliveSequence[401] = [false]
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertEqual(outcome.failedPids, [400])
        XCTAssertEqual(outcome.killedPids, [401])
    }

    // MARK: - 5. A survivor after the grace period (signal delivered, process ignores SIGTERM) is failed.

    func testSurvivorAfterGraceIsRecordedAsFailed() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [ProcessCandidate(pid: 500, command: "node \(serverEntry) --http")]
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[500] = [true, true, true] // stays alive through every grace check
        let service = makeService(query: query, signaling: signaling, graceAttempts: 3)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertEqual(outcome.failedPids, [500])
        XCTAssertTrue(outcome.killedPids.isEmpty)
    }

    // MARK: - 6. No candidates (or everything filtered out) -> hadNothingToKill, no signals sent.
    // Idempotent by construction: a second `reset()` call against a query that (correctly) now
    // reports no survivors reproduces this same "nothing to kill" outcome.

    func testNoCandidatesHasNothingToKillAndSendsNoSignals() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = []
        let signaling = FakeProcessSignaling()
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertTrue(outcome.hadNothingToKill)
        XCTAssertTrue(signaling.terminatedPids.isEmpty)
    }

    func testAllCandidatesFilteredOutAlsoHasNothingToKill() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [
            ProcessCandidate(pid: 700, command: "/usr/bin/unrelated-process --flag"),
            ProcessCandidate(pid: 100, command: "node \(serverEntry) --http"), // filtered as ownChildPid
        ]
        let signaling = FakeProcessSignaling()
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: 100)

        XCTAssertTrue(outcome.hadNothingToKill)
        XCTAssertTrue(signaling.terminatedPids.isEmpty)
    }

    // MARK: - 7. Only SIGTERM is ever reachable: the signaling protocol exposes no other way to
    // send a signal, so there is no code path in ProcessResetService that can escalate to SIGKILL.

    func testOnlyTerminateSigtermIsEverInvoked() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [ProcessCandidate(pid: 600, command: "node \(serverEntry) --http")]
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[600] = [false]
        let service = makeService(query: query, signaling: signaling)

        _ = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertEqual(signaling.terminatedPids, [600], "terminate() is the only signal-sending method ProcessSignaling exposes, and it sends SIGTERM")
    }

    // MARK: - Never touches a `claude` process even if its argv mentioned the serverEntry path.
    // This is the kill gate behind requirement 5: Reset never kills Claude Code.

    func testNeverSignalsAProcessNamedClaude() {
        let query = FakeProcessQuery()
        // Deliberately carries a bounded `--channel` token so this candidate passes the path AND
        // mode-flag rules — proving argv[0] != claude excludes it entirely on its own.
        query.candidatesToReturn = [
            ProcessCandidate(pid: 800, command: "claude --channel \(serverEntry)"),
        ]
        let signaling = FakeProcessSignaling()
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertTrue(signaling.terminatedPids.isEmpty, "claude itself must never be signaled, even if its argv mentions the serverEntry path")
        XCTAssertTrue(outcome.hadNothingToKill)
    }

    // MARK: - Adversarial argv matches: the serverEntry must appear as a whitespace-bounded
    // token, not a raw substring — sibling files (`.bak`, `.map`, logs) and longer paths that
    // merely END with the serverEntry path are DIFFERENT files and must never be signaled.

    func testServerEntryWithSuffixIsNeverSignaled() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [
            ProcessCandidate(pid: 900, command: "node \(serverEntry).bak --http"),
            ProcessCandidate(pid: 901, command: "tail -f \(serverEntry).output.log"),
        ]
        let signaling = FakeProcessSignaling()
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertTrue(signaling.terminatedPids.isEmpty, "\(serverEntry).bak / .log are different files — never signal their processes")
        XCTAssertTrue(outcome.hadNothingToKill)
    }

    func testServerEntryAsSuffixOfLongerPathIsNeverSignaled() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [
            ProcessCandidate(pid: 910, command: "node /backup\(serverEntry) --http"),
        ]
        let signaling = FakeProcessSignaling()
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertTrue(signaling.terminatedPids.isEmpty, "/backup\(serverEntry) is a different file — never signal its process")
        XCTAssertTrue(outcome.hadNothingToKill)
    }

    func testExactTokenMatchIsStillKilledAmongAdversarialSiblings() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [
            ProcessCandidate(pid: 920, command: "node \(serverEntry).bak --http"), // sibling, spared
            ProcessCandidate(pid: 921, command: "node \(serverEntry) --http"), // exact token, killed
            ProcessCandidate(pid: 922, command: "node /backup\(serverEntry) --channel"), // longer path, spared
            ProcessCandidate(pid: 923, command: "node \(serverEntry) --channel"), // exact token at end of command, killed
        ]
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[921] = [false]
        signaling.aliveSequence[923] = [false]
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertEqual(signaling.terminatedPids, [921, 923])
        XCTAssertEqual(outcome.killedPids, [921, 923])
    }

    // MARK: - Mode-flag requirement: even an exact serverEntry path match is NOT enough — the
    // command line must also carry a whitespace-bounded `--http` or `--channel` token (every
    // design-canvas helper runs with exactly one). This closes the residual class where a
    // crafted/stale health response names a real user-owned script path: without a mode flag,
    // an arbitrary `node <path>` process never qualifies.

    func testExactPathWithoutModeFlagIsNeverSignaled() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [
            ProcessCandidate(pid: 940, command: "node \(serverEntry)"),
            ProcessCandidate(pid: 941, command: "node \(serverEntry) --port 47100"),
        ]
        let signaling = FakeProcessSignaling()
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertTrue(signaling.terminatedPids.isEmpty, "an exact path match without --http/--channel is not a design-canvas helper — never signaled")
        XCTAssertTrue(outcome.hadNothingToKill)
    }

    func testModeFlagMustBeBoundedToken() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [
            ProcessCandidate(pid: 950, command: "node \(serverEntry) --httpx"), // spared: not a bounded --http
            ProcessCandidate(pid: 951, command: "node \(serverEntry) --channels"), // spared: not a bounded --channel
            ProcessCandidate(pid: 952, command: "node \(serverEntry) --http"), // bounded flag, killed
        ]
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[952] = [false]
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertEqual(signaling.terminatedPids, [952], "--httpx/--channels are different flags — the mode flag must match as a bounded token")
        XCTAssertEqual(outcome.killedPids, [952])
    }

    // MARK: - PosixSignaler errno interpretation (pure — never signals a real process).
    // ESRCH = target already dead = terminate's goal achieved = success (NOT failedPids);
    // any other errno (EPERM, EINVAL) stays a failure.

    func testEsrchMeansAlreadyDeadIsSuccessOtherErrnosAreFailure() {
        XCTAssertTrue(PosixSignaler.errnoMeansAlreadyDead(ESRCH))
        XCTAssertFalse(PosixSignaler.errnoMeansAlreadyDead(EPERM))
        XCTAssertFalse(PosixSignaler.errnoMeansAlreadyDead(EINVAL))
    }

    // Fake-level expression of the same contract end to end: a terminate that reports success
    // for an already-dead target (what PosixSignaler now returns on ESRCH), with isAlive
    // immediately false, lands the pid in killedPids — NOT failedPids.

    func testAlreadyDeadTargetLandsInKilledNotFailed() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [ProcessCandidate(pid: 930, command: "node \(serverEntry) --http")]
        let signaling = FakeProcessSignaling()
        signaling.terminateResult = { _ in true } // adapter maps ESRCH -> success
        signaling.aliveSequence[930] = [false]    // and the process is indeed gone
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(serverEntry: serverEntry, lastProbe: .refused, ownChildPid: nil)

        XCTAssertEqual(outcome.killedPids, [930])
        XCTAssertTrue(outcome.failedPids.isEmpty, "an already-dead helper is a success, not a failure")
    }

    // MARK: - Second reset source (plan-mandated): a healthy probe reporting a serverEntry
    // DIFFERENT from the configured one is only a HINT to also scan that path — ps verification
    // against real command lines remains the only thing that can ever trigger a signal.

    private func healthyProbe(instanceId: String?, serverEntry: String?) -> HealthProbeResult {
        .healthy(DaemonHealth(
            status: "ok",
            version: "0.0.0",
            channelAttached: false,
            pid: nil,
            instanceId: instanceId,
            startedAt: nil,
            serverEntry: serverEntry,
            port: 47100,
            channelCount: 0,
            channelAttachedAt: nil
        ))
    }

    func testForeignDaemonAtDifferentReportedServerEntryIsAlsoScannedAndKilled() {
        let foreignEntry = "/Users/other/checkout/dist/index.js"
        let query = FakeProcessQuery()
        query.candidatesByServerEntry[serverEntry] = [ProcessCandidate(pid: 111, command: "node \(serverEntry) --http")]
        query.candidatesByServerEntry[foreignEntry] = [ProcessCandidate(pid: 222, command: "node \(foreignEntry) --http")]
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[111] = [false]
        signaling.aliveSequence[222] = [false]
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(
            serverEntry: serverEntry,
            lastProbe: healthyProbe(instanceId: "foreign-instance", serverEntry: foreignEntry),
            ownChildPid: nil
        )

        XCTAssertEqual(Set(outcome.killedPids), [111, 222], "the reported foreign serverEntry's verified candidates are killed alongside the configured entry's")
        XCTAssertEqual(Set(query.queriedServerEntries), [serverEntry, foreignEntry], "both paths get queried")
    }

    func testReportedServerEntryWithNoMatchingPsCandidatesSignalsNothingForIt() {
        let foreignEntry = "/Users/other/checkout/dist/index.js"
        let query = FakeProcessQuery()
        query.candidatesByServerEntry[serverEntry] = [ProcessCandidate(pid: 111, command: "node \(serverEntry) --http")]
        // foreignEntry deliberately unset -> falls back to (empty) candidatesToReturn, i.e. a
        // lying/stale health response with nothing verified against real ps output.
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[111] = [false]
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(
            serverEntry: serverEntry,
            lastProbe: healthyProbe(instanceId: "foreign-instance", serverEntry: foreignEntry),
            ownChildPid: nil
        )

        XCTAssertEqual(outcome.killedPids, [111], "a reported path with nothing ps-verified signals nothing extra")
        XCTAssertEqual(signaling.terminatedPids, [111])
    }

    func testReportedServerEntryEqualToConfiguredDoesNotDoubleQueryOrKill() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [ProcessCandidate(pid: 111, command: "node \(serverEntry) --http")]
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[111] = [false]
        let service = makeService(query: query, signaling: signaling)

        let outcome = service.reset(
            serverEntry: serverEntry,
            lastProbe: healthyProbe(instanceId: "same-instance", serverEntry: serverEntry),
            ownChildPid: nil
        )

        XCTAssertEqual(outcome.killedPids, [111])
        XCTAssertEqual(signaling.terminatedPids, [111], "no duplicate signal for the same pid")
        XCTAssertEqual(query.queriedServerEntries, [serverEntry], "reported == configured -> queried exactly once, not twice")
    }

    func testHealthyProbeWithNilInstanceIdDoesNotTriggerSecondSource() {
        let query = FakeProcessQuery()
        query.candidatesToReturn = [ProcessCandidate(pid: 111, command: "node \(serverEntry) --http")]
        let signaling = FakeProcessSignaling()
        signaling.aliveSequence[111] = [false]
        let service = makeService(query: query, signaling: signaling)

        _ = service.reset(
            serverEntry: serverEntry,
            lastProbe: healthyProbe(instanceId: nil, serverEntry: "/some/other/path.js"),
            ownChildPid: nil
        )

        XCTAssertEqual(query.queriedServerEntries, [serverEntry], "no instanceId means no verified identity behind the reported path — no second query")
    }
}
