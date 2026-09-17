import XCTest
import CoreVideo
import Foundation

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine straight into
// it (see project.yml), so FrameRing is available without an import.

final class FrameRingTests: XCTestCase {

    private func makeBuffer(color: TestImages.RGBA = TestImages.RGBA(1, 2, 3)) -> CVPixelBuffer {
        TestImages.solidBGRAPixelBuffer(width: 4, height: 4, color: color)
    }

    func test_emptyRing_returnsNil() {
        let ring = FrameRing()
        XCTAssertNil(ring.frame(at: 1000))
    }

    func test_exactMatch_wins() {
        var ring = FrameRing()
        ring.append(makeBuffer(), captureMs: 1000)
        ring.append(makeBuffer(), captureMs: 2000)

        let found = ring.frame(at: 2000)
        XCTAssertEqual(found?.captureMs, 2000)
    }

    func test_nearestWithinTolerance_34ms() {
        var ring = FrameRing()
        ring.append(makeBuffer(), captureMs: 1000)

        let found = ring.frame(at: 1034)
        XCTAssertEqual(found?.captureMs, 1000)
    }

    func test_35msAway_returnsNil() {
        var ring = FrameRing()
        ring.append(makeBuffer(), captureMs: 1000)

        XCTAssertNil(ring.frame(at: 1035))
    }

    func test_tie_prefersOlder() {
        var ring = FrameRing()
        ring.append(makeBuffer(), captureMs: 1000) // older
        ring.append(makeBuffer(), captureMs: 1020) // newer; both 10ms from 1010

        let found = ring.frame(at: 1010)
        XCTAssertEqual(found?.captureMs, 1000)
    }

    func test_capacity16_evictsOldest() {
        var ring = FrameRing(capacity: 16)
        for i in 0..<17 {
            ring.append(makeBuffer(), captureMs: Int64(i))
        }
        XCTAssertEqual(ring.count, 16)
        XCTAssertNil(ring.frame(at: 0, toleranceMs: 0)) // frame 0 was evicted
        XCTAssertEqual(ring.frame(at: 16, toleranceMs: 0)?.captureMs, 16)
    }

    func test_append_deepCopies_BGRA() {
        var ring = FrameRing()
        let source = makeBuffer(color: TestImages.RGBA(10, 20, 30))
        ring.append(source, captureMs: 1)

        TestImages.setPixel(inBGRA: source, x: 0, y: 0, color: TestImages.RGBA(200, 200, 200))

        guard let stored = ring.frame(at: 1)?.pixelBuffer else {
            return XCTFail("expected a stored frame")
        }
        XCTAssertEqual(TestImages.pixel(inBGRA: stored, x: 0, y: 0), TestImages.RGBA(10, 20, 30))
    }

    func test_append_deepCopies_NV12() {
        var ring = FrameRing()
        let source = TestImages.solidNV12PixelBuffer(width: 4, height: 4, gray: 100)
        ring.append(source, captureMs: 1)

        TestImages.setLuma(inNV12: source, x: 0, y: 0, value: 250)

        guard let stored = ring.frame(at: 1)?.pixelBuffer else {
            return XCTFail("expected a stored frame")
        }
        let expectedLuma = TestImages.luma(inNV12: TestImages.solidNV12PixelBuffer(width: 4, height: 4, gray: 100), x: 0, y: 0)
        XCTAssertEqual(TestImages.luma(inNV12: stored, x: 0, y: 0), expectedLuma)
    }

    func test_removeAll() {
        var ring = FrameRing()
        ring.append(makeBuffer(), captureMs: 1)
        ring.append(makeBuffer(), captureMs: 2)
        ring.removeAll()

        XCTAssertEqual(ring.count, 0)
        XCTAssertNil(ring.frame(at: 1))
    }
}
