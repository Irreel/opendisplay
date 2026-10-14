import XCTest

/// The capture mode a sender starts in. OpenDisplay lets the user choose: what
/// they stored (the `mode` default, or the `-mode` launch argument), else
/// extend, as it has always been. A product built on the sender that supports
/// only one mode fixes it, and then nothing stored can select the other.
final class CaptureModeTests: XCTestCase {

    func testWithNothingFixedOrStoredASenderExtends() {
        XCTAssertEqual(CaptureMode.resolve(stored: nil, fixed: nil), .extend)
    }

    func testWithNothingFixedTheStoredModeWins() {
        XCTAssertEqual(CaptureMode.resolve(stored: "mirror", fixed: nil), .mirror)
        XCTAssertEqual(CaptureMode.resolve(stored: "extend", fixed: nil), .extend)
    }

    func testAnUnreadableStoredValueExtendsRatherThanFailing() {
        XCTAssertEqual(CaptureMode.resolve(stored: "", fixed: nil), .extend)
        XCTAssertEqual(CaptureMode.resolve(stored: "Mirror", fixed: nil), .extend)
        XCTAssertEqual(CaptureMode.resolve(stored: "sideways", fixed: nil), .extend)
    }

    func testAFixedModeIgnoresWhateverIsStored() {
        XCTAssertEqual(CaptureMode.resolve(stored: nil, fixed: .mirror), .mirror)
        XCTAssertEqual(CaptureMode.resolve(stored: "extend", fixed: .mirror), .mirror)
        XCTAssertEqual(CaptureMode.resolve(stored: "sideways", fixed: .mirror), .mirror)
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
