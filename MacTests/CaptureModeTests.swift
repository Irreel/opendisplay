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
}
