import XCTest
import CoreVideo
import Foundation

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine straight into
// it (see project.yml), so FrameRing is available without an import.

final class FrameRingTests: XCTestCase {

    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeBuffer(color: TestImages.RGBA = TestImages.RGBA(1, 2, 3)) -> CVPixelBuffer {
        TestImages.solidBGRAPixelBuffer(width: 4, height: 4, color: color)
    }

    func test_emptyRing_returnsNil() {
        let ring = FrameRing()
        XCTAssertNil(ring.frame(1))
    }

    /// A freeze names the frame the iPad is showing by number; the ring
    /// holds that frame or misses, it never offers a neighbour.
    func test_onlyAnExactNumberMatches() {
        var ring = FrameRing()
        ring.append(makeBuffer(), frame: 10, capturedAt: at)
        ring.append(makeBuffer(), frame: 12, capturedAt: at.addingTimeInterval(1))

        XCTAssertEqual(ring.frame(12)?.capturedAt, at.addingTimeInterval(1))
        XCTAssertNil(ring.frame(11))
        XCTAssertTrue(ring.contains(10))
        XCTAssertFalse(ring.contains(11))
    }

    func test_keepsEachFramesCaptureTime() {
        var ring = FrameRing()
        ring.append(makeBuffer(), frame: 1, capturedAt: at)
        XCTAssertEqual(ring.frame(1)?.capturedAt, at)
    }

    /// Several iPads encode the same captured frame; it is stored once.
    func test_aFrameAlreadyHeld_isNotStoredAgain() {
        var ring = FrameRing(capacity: 2)
        ring.append(makeBuffer(color: TestImages.RGBA(10, 0, 0)), frame: 1, capturedAt: at)
        ring.append(makeBuffer(color: TestImages.RGBA(20, 0, 0)), frame: 1, capturedAt: at)
        ring.append(makeBuffer(), frame: 2, capturedAt: at)

        XCTAssertEqual(ring.count, 2)
        guard let stored = ring.frame(1)?.pixelBuffer else { return XCTFail("frame 1 was evicted") }
        XCTAssertEqual(TestImages.pixel(inBGRA: stored, x: 0, y: 0), TestImages.RGBA(10, 0, 0))
    }

    func test_fullRing_evictsOldest() {
        let capacity = FrameRing.defaultCapacity
        var ring = FrameRing(capacity: capacity)
        for i in 0...capacity {
            ring.append(makeBuffer(), frame: UInt64(i), capturedAt: at)
        }
        XCTAssertEqual(ring.count, capacity)
        XCTAssertNil(ring.frame(0), "frame 0 was evicted")
        XCTAssertNotNil(ring.frame(UInt64(capacity)))
    }

    func test_append_deepCopies_BGRA() {
        var ring = FrameRing()
        let source = makeBuffer(color: TestImages.RGBA(10, 20, 30))
        ring.append(source, frame: 1, capturedAt: at)

        TestImages.setPixel(inBGRA: source, x: 0, y: 0, color: TestImages.RGBA(200, 200, 200))

        guard let stored = ring.frame(1)?.pixelBuffer else {
            return XCTFail("expected a stored frame")
        }
        XCTAssertEqual(TestImages.pixel(inBGRA: stored, x: 0, y: 0), TestImages.RGBA(10, 20, 30))
    }

    func test_append_deepCopies_NV12() {
        var ring = FrameRing()
        let source = TestImages.solidNV12PixelBuffer(width: 4, height: 4, gray: 100)
        ring.append(source, frame: 1, capturedAt: at)

        TestImages.setLuma(inNV12: source, x: 0, y: 0, value: 250)

        guard let stored = ring.frame(1)?.pixelBuffer else {
            return XCTFail("expected a stored frame")
        }
        let expectedLuma = TestImages.luma(inNV12: TestImages.solidNV12PixelBuffer(width: 4, height: 4, gray: 100), x: 0, y: 0)
        XCTAssertEqual(TestImages.luma(inNV12: stored, x: 0, y: 0), expectedLuma)
    }

    // MARK: - CleanFrameStore

    func test_store_keepsACopy_andAnswersByNumber() {
        let store = CleanFrameStore(capacity: 4)
        let source = makeBuffer(color: TestImages.RGBA(10, 20, 30))
        store.keep(source, frame: 5, capturedAt: at)
        TestImages.setPixel(inBGRA: source, x: 0, y: 0, color: TestImages.RGBA(200, 200, 200))

        guard let found = store.cleanFrame(5) else { return XCTFail("expected frame 5") }
        XCTAssertEqual(found.capturedAt, at)
        XCTAssertEqual(TestImages.pixel(inBGRA: found.pixelBuffer, x: 0, y: 0), TestImages.RGBA(10, 20, 30))
        XCTAssertNil(store.cleanFrame(6))
    }
}
