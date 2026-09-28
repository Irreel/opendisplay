import XCTest

/// Design Canvas mirrors the Mac's screen and does nothing else (owner
/// decisions, 2026-09-17: PRD open question G1 resolved to "mirror", then the
/// extended display dropped as a feature). The sender it is built on also
/// reads a stored `mode`, so the mode has to be fixed, not merely defaulted:
/// a `mode = extend` left in the defaults must not bring back a display this
/// product has no UI, no documentation and no support for.
final class CanvasCaptureModeTests: XCTestCase {

    func testDesignCanvasMirrors() {
        XCTAssertEqual(CaptureMode.designCanvas, .mirror)
        XCTAssertEqual(CaptureMode.resolve(stored: nil, fixed: .designCanvas), .mirror)
    }

    func testAStoredExtendCannotTakeItOutOfMirroring() {
        XCTAssertEqual(CaptureMode.resolve(stored: "extend", fixed: .designCanvas), .mirror)
    }
}
