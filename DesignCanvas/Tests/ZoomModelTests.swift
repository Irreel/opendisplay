import XCTest
import CoreGraphics

// NOTE: this hostless bundle compiles DesignCanvas/iOS/Logic straight into it
// (see project.yml), so ZoomModel is available without an import.

final class ZoomModelTests: XCTestCase {

    // A square view and a square video: the fitted rect is the whole view, so
    // every number below is the zoom maths and nothing else.
    private let squareView = CGSize(width: 1000, height: 1000)
    private let squareVideo = CGSize(width: 1000, height: 1000)

    private func assertRect(_ rect: NormalizedRect,
                            _ expected: NormalizedRect,
                            accuracy: Double = 1e-9,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertEqual(rect.x, expected.x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(rect.y, expected.y, accuracy: accuracy, "y", file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }

    // MARK: - fittedRect

    func test_fittedRect_videoWiderThanTheView_letterboxesTopAndBottom() {
        // 1600x1000 (1.6) inside 1000x800 (1.25): width binds.
        let rect = ZoomModel.fittedRect(videoSize: CGSize(width: 1600, height: 1000),
                                        in: CGSize(width: 1000, height: 800))
        XCTAssertEqual(rect.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(rect.origin.y, 87.5, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 1000, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 625, accuracy: 1e-9)
    }

    func test_fittedRect_videoTallerThanTheView_pillarboxesLeftAndRight() {
        // 1000x1600 (0.625) inside 1000x800 (1.25): height binds.
        let rect = ZoomModel.fittedRect(videoSize: CGSize(width: 1000, height: 1600),
                                        in: CGSize(width: 1000, height: 800))
        XCTAssertEqual(rect.origin.x, 250, accuracy: 1e-9)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 500, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 800, accuracy: 1e-9)
    }

    func test_fittedRect_withoutAVideoSize_isEmpty() {
        let rect = ZoomModel.fittedRect(videoSize: .zero, in: squareView)
        XCTAssertEqual(rect, .zero)
    }

    // MARK: - scale clamping

    func test_pinch_clampsAtTheMinimumScale() {
        var model = ZoomModel()
        model.pinch(by: 0.5, anchor: CGPoint(x: 500, y: 500),
                    viewSize: squareView, videoSize: squareVideo)
        XCTAssertEqual(model.scale, ZoomModel.minScale, accuracy: 1e-9)
        XCTAssertEqual(model.scale, 1, accuracy: 1e-9)
    }

    func test_pinch_clampsAtTheMaximumScale() {
        var model = ZoomModel()
        model.pinch(by: 100, anchor: CGPoint(x: 500, y: 500),
                    viewSize: squareView, videoSize: squareVideo)
        XCTAssertEqual(model.scale, ZoomModel.maxScale, accuracy: 1e-9)
        XCTAssertEqual(model.scale, 6, accuracy: 1e-9)
    }

    func test_pinch_multipliesTheCurrentScale() {
        var model = ZoomModel()
        model.pinch(by: 2, anchor: CGPoint(x: 500, y: 500),
                    viewSize: squareView, videoSize: squareVideo)
        model.pinch(by: 1.5, anchor: CGPoint(x: 500, y: 500),
                    viewSize: squareView, videoSize: squareVideo)
        XCTAssertEqual(model.scale, 3, accuracy: 1e-9)
    }

    // MARK: - scale 1

    func test_atScaleOne_visibleRectIsTheWholeVideo() {
        let model = ZoomModel()
        assertRect(model.visibleRect(viewSize: squareView, videoSize: squareVideo), .full)
        XCTAssertTrue(model.visibleRect(viewSize: squareView, videoSize: squareVideo).isFull)
    }

    func test_atScaleOne_aLetterboxedVideoStillShowsTheWholeVideo() {
        let model = ZoomModel()
        let rect = model.visibleRect(viewSize: CGSize(width: 1000, height: 800),
                                     videoSize: CGSize(width: 1600, height: 1000))
        assertRect(rect, .full)
    }

    func test_atScaleOne_panIsANoOp() {
        var model = ZoomModel()
        model.pan(by: CGSize(width: 100, height: 100),
                  viewSize: squareView, videoSize: squareVideo)
        XCTAssertEqual(model.offset, .zero)
        assertRect(model.visibleRect(viewSize: squareView, videoSize: squareVideo), .full)
    }

    // MARK: - pinch anchoring

    func test_pinchTwiceAtTheCentre_showsTheCentredHalfOfTheVideo() {
        var model = ZoomModel()
        model.pinch(by: 2, anchor: CGPoint(x: 500, y: 500),
                    viewSize: squareView, videoSize: squareVideo)
        XCTAssertEqual(model.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(model.offset, .zero)
        assertRect(model.visibleRect(viewSize: squareView, videoSize: squareVideo),
                   NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    func test_pinchAtACorner_keepsThatCornerOnTheSameVideoPixel() {
        var model = ZoomModel()
        model.pinch(by: 2, anchor: .zero, viewSize: squareView, videoSize: squareVideo)
        // The top-left corner of the view was showing the video's origin, and
        // still is: the visible region grows out of that corner.
        assertRect(model.visibleRect(viewSize: squareView, videoSize: squareVideo),
                   NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5))

        var other = ZoomModel()
        other.pinch(by: 2, anchor: CGPoint(x: 1000, y: 1000),
                    viewSize: squareView, videoSize: squareVideo)
        assertRect(other.visibleRect(viewSize: squareView, videoSize: squareVideo),
                   NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    // MARK: - pan clamping

    func test_pan_clampsAtTheTopLeftEdge() {
        var model = ZoomModel()
        model.pinch(by: 2, anchor: CGPoint(x: 500, y: 500),
                    viewSize: squareView, videoSize: squareVideo)
        // Dragging the video right and down reveals its top-left corner, and
        // stops the moment that corner reaches the view's corner.
        model.pan(by: CGSize(width: 10_000, height: 10_000),
                  viewSize: squareView, videoSize: squareVideo)
        XCTAssertEqual(model.offset.width, 500, accuracy: 1e-9)
        XCTAssertEqual(model.offset.height, 500, accuracy: 1e-9)
        assertRect(model.visibleRect(viewSize: squareView, videoSize: squareVideo),
                   NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5))
    }

    func test_pan_clampsAtTheBottomRightEdge() {
        var model = ZoomModel()
        model.pinch(by: 2, anchor: CGPoint(x: 500, y: 500),
                    viewSize: squareView, videoSize: squareVideo)
        model.pan(by: CGSize(width: -10_000, height: -10_000),
                  viewSize: squareView, videoSize: squareVideo)
        XCTAssertEqual(model.offset.width, -500, accuracy: 1e-9)
        XCTAssertEqual(model.offset.height, -500, accuracy: 1e-9)
        assertRect(model.visibleRect(viewSize: squareView, videoSize: squareVideo),
                   NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    func test_pan_withinTheEdgesMovesTheVisibleRegion() {
        var model = ZoomModel()
        model.pinch(by: 2, anchor: CGPoint(x: 500, y: 500),
                    viewSize: squareView, videoSize: squareVideo)
        model.pan(by: CGSize(width: 200, height: -100),
                  viewSize: squareView, videoSize: squareVideo)
        XCTAssertEqual(model.offset.width, 200, accuracy: 1e-9)
        XCTAssertEqual(model.offset.height, -100, accuracy: 1e-9)
        // The video is 2000 points wide once doubled, so dragging it 200 points
        // right slides the visible window 0.1 of the video to the left of
        // centre (0.25 - 0.1), and lifting it 100 points slides it 0.05 down.
        assertRect(model.visibleRect(viewSize: squareView, videoSize: squareVideo),
                   NormalizedRect(x: 0.15, y: 0.3, width: 0.5, height: 0.5))
    }

    func test_pan_onTheLetterboxedAxisStaysCentredWhileTheVideoDoesNotCoverTheView() {
        // 1600x1000 in 1000x800 fits to 1000x625. At 1.2x the height is 750,
        // still short of 800, so there is nothing to pan to vertically.
        let view = CGSize(width: 1000, height: 800)
        let video = CGSize(width: 1600, height: 1000)
        var model = ZoomModel()
        model.pinch(by: 1.2, anchor: CGPoint(x: 500, y: 400), viewSize: view, videoSize: video)
        model.pan(by: CGSize(width: 0, height: 500), viewSize: view, videoSize: video)
        XCTAssertEqual(model.offset.height, 0, accuracy: 1e-9)
    }

    // MARK: - lock

    func test_lockedModel_ignoresPinchAndPan() {
        var model = ZoomModel()
        model.pinch(by: 2, anchor: CGPoint(x: 500, y: 500),
                    viewSize: squareView, videoSize: squareVideo)
        let locked = { () -> ZoomModel in
            var copy = model
            copy.isLocked = true
            return copy
        }()

        var underTest = locked
        underTest.pinch(by: 3, anchor: .zero, viewSize: squareView, videoSize: squareVideo)
        underTest.pan(by: CGSize(width: 300, height: 300),
                      viewSize: squareView, videoSize: squareVideo)
        XCTAssertEqual(underTest, locked)
        XCTAssertEqual(underTest.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(underTest.offset, .zero)
    }

    // MARK: - reset

    func test_reset_returnsToTheFittedVideoAndKeepsTheLock() {
        var model = ZoomModel()
        model.pinch(by: 4, anchor: .zero, viewSize: squareView, videoSize: squareVideo)
        model.pan(by: CGSize(width: -200, height: 0),
                  viewSize: squareView, videoSize: squareVideo)
        model.isLocked = true
        model.reset()
        XCTAssertEqual(model.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(model.offset, .zero)
        XCTAssertTrue(model.isLocked)
        assertRect(model.visibleRect(viewSize: squareView, videoSize: squareVideo), .full)
    }
}
