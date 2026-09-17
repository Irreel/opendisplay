import XCTest

// NOTE: this hostless bundle compiles DesignCanvas/Shared straight into it
// (see project.yml), so DrawModeStateMachine is available without an import.

final class DrawModeStateMachineTests: XCTestCase {

    // MARK: - Table row: live + enterDrawMode -> freezing

    func test_live_enterDrawMode_entersFreezingAndPausesSyncAndSendsFreeze() {
        var sm = DrawModeStateMachine()
        let effects = sm.handle(.enterDrawMode(now: 100))
        XCTAssertEqual(sm.state, .freezing(deadline: 102))
        XCTAssertEqual(effects, [.pauseSync, .sendFreeze])
    }

    // MARK: - Table row: freezing + frozen(ok: true) -> drawing

    func test_freezing_frozenOk_entersDrawing() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        let effects = sm.handle(.frozen(ok: true))
        XCTAssertEqual(sm.state, .drawing)
        XCTAssertEqual(effects, [])
    }

    // MARK: - Table row: freezing + frozen(ok: false) -> live

    func test_freezing_frozenNotOk_returnsToLiveWithNoFrameNotice() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        let effects = sm.handle(.frozen(ok: false))
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.resumeSync, .show(.noFrame)])
    }

    // MARK: - Table row: freezing + tick(now >= deadline) -> live, timed out

    func test_freezing_tickAtOrAfterDeadline_timesOutToLive() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        let effects = sm.handle(.tick(now: 2))
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.resumeSync, .show(.freezeTimedOut)])
    }

    // Plus: tick before the deadline does nothing.
    func test_freezing_tickBeforeDeadline_doesNothing() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        let effects = sm.handle(.tick(now: 1.999))
        XCTAssertEqual(sm.state, .freezing(deadline: 2))
        XCTAssertEqual(effects, [])
    }

    // MARK: - Table row: freezing/drawing + cancel -> live

    func test_freezing_cancel_returnsToLive() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        let effects = sm.handle(.cancel)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.resumeSync])
    }

    func test_drawing_cancel_returnsToLive() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        let effects = sm.handle(.cancel)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.resumeSync])
    }

    // MARK: - Table row: freezing/drawing + discard -> live, clears strokes

    func test_freezing_discard_returnsToLiveAndClearsStrokes() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        let effects = sm.handle(.discard)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.resumeSync, .clearStrokes])
    }

    func test_drawing_discard_returnsToLiveAndClearsStrokes() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        let effects = sm.handle(.discard)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.resumeSync, .clearStrokes])
    }

    // MARK: - Table row: freezing/drawing + rotated -> live, interrupted notice

    func test_freezing_rotated_returnsToLiveWithInterruptedByRotationNotice() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        let effects = sm.handle(.rotated)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.resumeSync, .show(.interruptedByRotation)])
    }

    func test_drawing_rotated_returnsToLiveWithInterruptedByRotationNotice() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        let effects = sm.handle(.rotated)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.resumeSync, .show(.interruptedByRotation)])
    }

    // MARK: - Table row: freezing/drawing + linkLost -> live, interrupted notice

    func test_freezing_linkLost_returnsToLiveWithInterruptedByLinkLossNotice() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        let effects = sm.handle(.linkLost)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.resumeSync, .show(.interruptedByLinkLoss)])
    }

    func test_drawing_linkLost_returnsToLiveWithInterruptedByLinkLossNotice() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        let effects = sm.handle(.linkLost)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.resumeSync, .show(.interruptedByLinkLoss)])
    }

    // MARK: - Table row: drawing + done (strokeCount >= 1) -> sending

    func test_drawing_doneWithStrokes_entersSending() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        _ = sm.handle(.strokeCountChanged(1))
        let effects = sm.handle(.done)
        XCTAssertEqual(sm.state, .sending)
        XCTAssertEqual(effects, [.sendAnnotation, .resumeSync])
    }

    // MARK: - Table row: sending + sent -> live

    func test_sending_sent_returnsToLiveAndClearsStrokes() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        _ = sm.handle(.strokeCountChanged(1))
        _ = sm.handle(.done)
        let effects = sm.handle(.sent)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.clearStrokes])
    }

    // MARK: - Table row: sending + linkLost -> retry

    func test_sending_linkLost_entersRetry() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        _ = sm.handle(.strokeCountChanged(1))
        _ = sm.handle(.done)
        let effects = sm.handle(.linkLost)
        XCTAssertEqual(sm.state, .retry)
        XCTAssertEqual(effects, [])
    }

    // MARK: - Table row: retry + helloReceived -> sending

    func test_retry_helloReceived_reentersSendingAndResendsAnnotation() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        _ = sm.handle(.strokeCountChanged(1))
        _ = sm.handle(.done)
        _ = sm.handle(.linkLost)
        let effects = sm.handle(.helloReceived)
        XCTAssertEqual(sm.state, .sending)
        XCTAssertEqual(effects, [.sendAnnotation])
    }

    // MARK: - Table row: any + strokeCountChanged(n) -> unchanged, records max(0, n)

    func test_strokeCountChanged_leavesStateUnchangedAndClampsAtZero() {
        var sm = DrawModeStateMachine()
        let effects = sm.handle(.strokeCountChanged(3))
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(sm.strokeCount, 3)

        let effects2 = sm.handle(.strokeCountChanged(-5))
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects2, [])
        XCTAssertEqual(sm.strokeCount, 0)
    }

    // MARK: - Second enterDrawMode while already in draw mode is ignored

    func test_secondEnterDrawMode_whileFreezing_isIgnored() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        let before = sm.state
        let effects = sm.handle(.enterDrawMode(now: 50))
        XCTAssertEqual(sm.state, before)
        XCTAssertEqual(effects, [])
    }

    func test_secondEnterDrawMode_whileDrawing_isIgnored() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        let before = sm.state
        let effects = sm.handle(.enterDrawMode(now: 50))
        XCTAssertEqual(sm.state, before)
        XCTAssertEqual(effects, [])
    }

    // MARK: - done with zero strokes is ignored

    func test_drawing_doneWithZeroStrokes_isIgnored() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        let effects = sm.handle(.done)
        XCTAssertEqual(sm.state, .drawing)
        XCTAssertEqual(effects, [])
    }

    // MARK: - canSend is false in freezing even with strokes

    func test_canSend_falseWhileFreezingEvenWithStrokes() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.strokeCountChanged(4))
        XCTAssertFalse(sm.canSend)
        XCTAssertTrue(sm.isInDrawMode)
    }

    // MARK: - Full happy path

    func test_fullHappyPath_liveToFreezingToDrawingToSendingToLive() {
        var sm = DrawModeStateMachine()
        XCTAssertEqual(sm.state, .live)
        XCTAssertFalse(sm.isInDrawMode)

        var effects = sm.handle(.enterDrawMode(now: 10))
        XCTAssertEqual(sm.state, .freezing(deadline: 12))
        XCTAssertEqual(effects, [.pauseSync, .sendFreeze])
        XCTAssertTrue(sm.isInDrawMode)
        XCTAssertFalse(sm.canSend)

        effects = sm.handle(.frozen(ok: true))
        XCTAssertEqual(sm.state, .drawing)
        XCTAssertEqual(effects, [])
        XCTAssertTrue(sm.isInDrawMode)
        XCTAssertFalse(sm.canSend)

        effects = sm.handle(.strokeCountChanged(2))
        XCTAssertEqual(effects, [])
        XCTAssertTrue(sm.canSend)

        effects = sm.handle(.done)
        XCTAssertEqual(sm.state, .sending)
        XCTAssertEqual(effects, [.sendAnnotation, .resumeSync])
        XCTAssertFalse(sm.isInDrawMode)

        effects = sm.handle(.sent)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.clearStrokes])
    }

    // MARK: - Retry path

    func test_retryPath_sendingToRetryToSendingToLive() {
        var sm = DrawModeStateMachine()
        _ = sm.handle(.enterDrawMode(now: 0))
        _ = sm.handle(.frozen(ok: true))
        _ = sm.handle(.strokeCountChanged(1))
        _ = sm.handle(.done)

        var effects = sm.handle(.linkLost)
        XCTAssertEqual(sm.state, .retry)
        XCTAssertEqual(effects, [])

        effects = sm.handle(.helloReceived)
        XCTAssertEqual(sm.state, .sending)
        XCTAssertEqual(effects, [.sendAnnotation])

        effects = sm.handle(.sent)
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [.clearStrokes])
    }

    // MARK: - frozen arriving in live is ignored

    func test_frozen_arrivingInLive_isIgnored() {
        var sm = DrawModeStateMachine()
        let effects = sm.handle(.frozen(ok: true))
        XCTAssertEqual(sm.state, .live)
        XCTAssertEqual(effects, [])
    }
}
