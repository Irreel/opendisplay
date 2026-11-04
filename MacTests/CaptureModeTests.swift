import XCTest

/// The capture mode a sender starts in: what the user stored (the `mode`
/// default, or the `-mode` launch argument), else extend, as it has always
/// been.
final class CaptureModeTests: XCTestCase {

    func testWithNothingStoredASenderExtends() {
        XCTAssertEqual(CaptureMode.resolve(stored: nil), .extend)
    }

    func testTheStoredModeWins() {
        XCTAssertEqual(CaptureMode.resolve(stored: "mirror"), .mirror)
        XCTAssertEqual(CaptureMode.resolve(stored: "extend"), .extend)
    }

    func testAnUnreadableStoredValueExtendsRatherThanFailing() {
        XCTAssertEqual(CaptureMode.resolve(stored: ""), .extend)
        XCTAssertEqual(CaptureMode.resolve(stored: "Mirror"), .extend)
        XCTAssertEqual(CaptureMode.resolve(stored: "sideways"), .extend)
    }

    // MARK: - Recovering a capture that died

    func testADeadExtendCaptureRetriesQuicklyThenEndsTheSession() {
        XCTAssertEqual(CaptureMode.extend.recoveryStep(afterFailures: 1, cap: 5), .retry(after: 3))
        XCTAssertEqual(CaptureMode.extend.recoveryStep(afterFailures: 4, cap: 5), .retry(after: 3))
        XCTAssertEqual(CaptureMode.extend.recoveryStep(afterFailures: 5, cap: 5), .endSession)
    }

    /// A mirror's display is the Mac's own screen: a lock or display sleep
    /// takes it away for as long as the user is gone, and it always comes
    /// back. Giving up would leave the receiver on a frozen frame.
    func testADeadMirrorCaptureSlowsDownButNeverGivesUp() {
        XCTAssertEqual(CaptureMode.mirror.recoveryStep(afterFailures: 1, cap: 5), .retry(after: 3))
        XCTAssertEqual(CaptureMode.mirror.recoveryStep(afterFailures: 4, cap: 5), .retry(after: 3))
        XCTAssertEqual(CaptureMode.mirror.recoveryStep(afterFailures: 5, cap: 5), .retry(after: 30))
        XCTAssertEqual(CaptureMode.mirror.recoveryStep(afterFailures: 5000, cap: 5), .retry(after: 30))
    }
}
