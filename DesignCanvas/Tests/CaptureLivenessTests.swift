import XCTest

/// "Capturing" as the menu understands it: a frame reached the Design Canvas engine within the
/// last two seconds. This is the ground truth behind the Screen Recording row — a permission
/// preflight that disagrees with a running capture is the preflight being wrong.
final class CaptureLivenessTests: XCTestCase {
    func testNoFramesMeansNotCapturing() {
        let status = CanvasStatus()
        XCTAssertFalse(status.isCapturing(now: Date()))
    }

    func testARecentFrameMeansCapturing() {
        let status = CanvasStatus()
        let t = Date()
        status.noteFrame(at: t)
        XCTAssertTrue(status.isCapturing(now: t.addingTimeInterval(1)))
    }

    func testAStaleFrameMeansCaptureStopped() {
        let status = CanvasStatus()
        let t = Date()
        status.noteFrame(at: t)
        XCTAssertFalse(status.isCapturing(now: t.addingTimeInterval(3)))
    }
}
