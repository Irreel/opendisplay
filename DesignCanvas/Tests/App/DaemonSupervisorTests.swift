import XCTest

/// Ported from ai.cst.2 `DesignCanvasDesktopTests/DaemonSupervisorTests.swift`.
@MainActor
final class FakeRunner: ProcessRunning {
    var started = 0
    var stopped = 0
    var pid: Int32?
    var onExit: ((Int32) -> Void)?
    func start(onExit: @escaping (Int32) -> Void) { started += 1; self.onExit = onExit }
    func stop() { stopped += 1 }
    func simulateExit(code: Int32) { onExit?(code) }
}

/// Injectable clock for crash-loop tests; avoids real sleeps.
final class TestClock {
    var current = Date(timeIntervalSince1970: 0)
    func now() -> Date { current }
    func advance(_ interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}

@MainActor
final class DaemonSupervisorTests: XCTestCase {
    func testStartsRunner() {
        let runner = FakeRunner()
        let s = DaemonSupervisor(runner: runner)
        s.start()
        XCTAssertEqual(runner.started, 1)
        XCTAssertEqual(s.state, .running)
    }

    func testRestartsOnUnexpectedExit() {
        let runner = FakeRunner()
        let s = DaemonSupervisor(runner: runner, restartDelay: 0)
        s.start()
        runner.simulateExit(code: 1)
        XCTAssertEqual(runner.started, 2) // restarted
    }

    func testStopPreventsRestart() {
        let runner = FakeRunner()
        let s = DaemonSupervisor(runner: runner, restartDelay: 0)
        s.start()
        s.stop()
        runner.simulateExit(code: 0)
        XCTAssertEqual(runner.started, 1) // no restart after intentional stop
        XCTAssertEqual(s.state, .stopped)
    }

    // MARK: - childPid

    func testChildPidReflectsRunnerPidWhileRunning() {
        let runner = FakeRunner()
        runner.pid = 4242
        let s = DaemonSupervisor(runner: runner)
        s.start()
        XCTAssertEqual(s.childPid, 4242)
    }

    func testChildPidNilAfterStop() {
        let runner = FakeRunner()
        runner.pid = 777
        let s = DaemonSupervisor(runner: runner, restartDelay: 0)
        s.start()
        s.stop()
        XCTAssertNil(s.childPid)
    }

    func testChildPidNilAfterExitBeforeRestart() {
        let runner = FakeRunner()
        runner.pid = 555
        // Nonzero restartDelay so the scheduled restart doesn't run synchronously
        // within this test, letting us observe the nil gap after exit.
        let s = DaemonSupervisor(runner: runner, restartDelay: 1.0)
        s.start()
        XCTAssertEqual(s.childPid, 555)
        runner.simulateExit(code: 1)
        XCTAssertNil(s.childPid)
    }

    // MARK: - crash-loop guard (1.0 s restart delay / 2.0 s fast-exit threshold / 3 strikes)

    func testThreeConsecutiveFastExitsGivesUp() {
        let runner = FakeRunner()
        let clock = TestClock()
        let s = DaemonSupervisor(runner: runner, restartDelay: 0, fastExitThreshold: 2.0, maxConsecutiveFastExits: 3, now: clock.now)
        var giveUpCount = 0
        s.onGiveUp = { giveUpCount += 1 }
        s.start()
        clock.advance(0.1); runner.simulateExit(code: 1) // fast exit 1 -> restart
        clock.advance(0.1); runner.simulateExit(code: 1) // fast exit 2 -> restart
        clock.advance(0.1); runner.simulateExit(code: 1) // fast exit 3 -> give up, no 4th start
        XCTAssertEqual(runner.started, 3)
        XCTAssertEqual(s.state, .gaveUp)
        XCTAssertEqual(giveUpCount, 1)
    }

    func testTwoFastExitsThenLongRunResetsCounter() {
        let runner = FakeRunner()
        let clock = TestClock()
        let s = DaemonSupervisor(runner: runner, restartDelay: 0, fastExitThreshold: 2.0, maxConsecutiveFastExits: 3, now: clock.now)
        var giveUpCount = 0
        s.onGiveUp = { giveUpCount += 1 }
        s.start()
        clock.advance(0.1); runner.simulateExit(code: 1) // fast exit 1 -> restart
        clock.advance(0.1); runner.simulateExit(code: 1) // fast exit 2 -> restart
        clock.advance(5.0); runner.simulateExit(code: 1) // long run then crash -> counter resets, restart
        clock.advance(0.1); runner.simulateExit(code: 1) // one more fast exit, but counter only at 1
        XCTAssertEqual(runner.started, 5)
        XCTAssertEqual(s.state, .running)
        XCTAssertEqual(giveUpCount, 0)
    }

    func testExplicitRestartAfterGaveUpStartsAgain() {
        let runner = FakeRunner()
        let clock = TestClock()
        let s = DaemonSupervisor(runner: runner, restartDelay: 0, fastExitThreshold: 2.0, maxConsecutiveFastExits: 3, now: clock.now)
        s.start()
        clock.advance(0.1); runner.simulateExit(code: 1)
        clock.advance(0.1); runner.simulateExit(code: 1)
        clock.advance(0.1); runner.simulateExit(code: 1) // gives up
        XCTAssertEqual(s.state, .gaveUp)
        s.start() // explicit restart clears the counter and tries again
        XCTAssertEqual(s.state, .running)
        XCTAssertEqual(runner.started, 4)
    }

    // REGRESSION: a crash after running longer than the threshold still restarts.
    func testSlowCrashStillRestarts() {
        let runner = FakeRunner()
        let clock = TestClock()
        let s = DaemonSupervisor(runner: runner, restartDelay: 0, fastExitThreshold: 2.0, now: clock.now)
        s.start()
        clock.advance(10.0)
        runner.simulateExit(code: 1)
        XCTAssertEqual(runner.started, 2)
        XCTAssertEqual(s.state, .running)
    }

    // MARK: - the shipped defaults are the plan's crash-loop guard values.

    func testDefaultGuardIsOneSecondDelayTwoSecondThresholdThreeStrikes() {
        let runner = FakeRunner()
        let clock = TestClock()
        let s = DaemonSupervisor(runner: runner, restartDelay: 0, now: clock.now)
        var gaveUp = false
        s.onGiveUp = { gaveUp = true }
        s.start()
        // 1.9 s is inside the default 2.0 s fast-exit threshold; three of them trip the guard.
        clock.advance(1.9); runner.simulateExit(code: 1)
        clock.advance(1.9); runner.simulateExit(code: 1)
        XCTAssertFalse(gaveUp, "two strikes is not enough with the default maxConsecutiveFastExits of 3")
        clock.advance(1.9); runner.simulateExit(code: 1)
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(runner.started, 3)
    }
}
