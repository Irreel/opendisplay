import XCTest
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine straight into
// it (see project.yml), so Compositor is available without an import.

final class CompositorTests: XCTestCase {

    // MARK: - composite()

    func test_fullRect_keepsSizeAndBaseColors() throws {
        let base = TestImages.solidCGImage(width: 400, height: 300, color: TestImages.RGBA(10, 20, 30))

        let result = try Compositor.composite(base: base, sketchPNG: Data(), zoomRect: .full)

        XCTAssertEqual(result.compositeSize, CGSize(width: 400, height: 300))
        assertColor(TestImages.pixel(inPNG: result.compositePNG, x: 200, y: 150), TestImages.RGBA(10, 20, 30))
    }

    func test_sketch_opaqueOverridesTransparentShowsBase() throws {
        let base = TestImages.solidCGImage(width: 100, height: 100, color: TestImages.RGBA(0, 0, 0))
        let sketch = TestImages.rectOnTransparentCGImage(
            width: 100, height: 100,
            rect: CGRect(x: 10, y: 10, width: 20, height: 20),
            fill: TestImages.RGBA(255, 0, 0)
        )
        let sketchPNG = TestImages.pngData(sketch)

        let result = try Compositor.composite(base: base, sketchPNG: sketchPNG, zoomRect: .full)

        assertColor(TestImages.pixel(inPNG: result.compositePNG, x: 15, y: 15), TestImages.RGBA(255, 0, 0))
        assertColor(TestImages.pixel(inPNG: result.compositePNG, x: 50, y: 50), TestImages.RGBA(0, 0, 0))
    }

    func test_zoomRect_rightHalf_ofLeftBlueRightGreen_givesAllGreen() throws {
        let base = TestImages.leftRightCGImage(width: 400, height: 300, left: TestImages.RGBA(0, 0, 255), right: TestImages.RGBA(0, 255, 0))
        let zoomRect = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)

        let result = try Compositor.composite(base: base, sketchPNG: Data(), zoomRect: zoomRect)

        XCTAssertEqual(result.compositeSize, CGSize(width: 200, height: 300))
        for point in [(0, 0), (199, 0), (0, 299), (199, 299), (100, 150)] {
            assertColor(TestImages.pixel(inPNG: result.compositePNG, x: point.0, y: point.1), TestImages.RGBA(0, 255, 0))
        }
    }

    /// This is the test the coordinate-convention ruling calls for: it would
    /// fail if the crop were vertically mirrored, since a flipped crop of a
    /// red-top/blue-bottom base's top half would come out blue instead.
    func test_zoomRect_topHalf_ofRedTopBlueBottom_givesAllRed_notFlipped() throws {
        let base = TestImages.topBottomCGImage(width: 200, height: 200, top: TestImages.RGBA(255, 0, 0), bottom: TestImages.RGBA(0, 0, 255))
        let zoomRect = NormalizedRect(x: 0, y: 0, width: 1, height: 0.5)

        let result = try Compositor.composite(base: base, sketchPNG: Data(), zoomRect: zoomRect)

        XCTAssertEqual(result.compositeSize, CGSize(width: 200, height: 100))
        for point in [(0, 0), (199, 0), (0, 99), (199, 99), (100, 50)] {
            assertColor(TestImages.pixel(inPNG: result.compositePNG, x: point.0, y: point.1), TestImages.RGBA(255, 0, 0))
        }
    }

    func test_largeBase_scaledDownToMaxLongSide() throws {
        let base = TestImages.solidCGImage(width: 4000, height: 2000, color: TestImages.RGBA(1, 2, 3))

        let result = try Compositor.composite(base: base, sketchPNG: Data(), zoomRect: .full)

        XCTAssertEqual(result.compositeSize, CGSize(width: 1568, height: 784))
    }

    func test_smallBase_isNotUpscaled() throws {
        let base = TestImages.solidCGImage(width: 100, height: 50, color: TestImages.RGBA(1, 2, 3))

        let result = try Compositor.composite(base: base, sketchPNG: Data(), zoomRect: .full)

        XCTAssertEqual(result.compositeSize, CGSize(width: 100, height: 50))
    }

    func test_zoomRect_partlyOutside_isClampedWithoutCrashing() throws {
        let base = TestImages.solidCGImage(width: 400, height: 300, color: TestImages.RGBA(9, 9, 9))
        let zoomRect = NormalizedRect(x: 0.8, y: 0, width: 0.5, height: 1) // spans [0.8, 1.3) of x

        let result = try Compositor.composite(base: base, sketchPNG: Data(), zoomRect: zoomRect)

        XCTAssertEqual(result.cropRectPixels.width, 80) // clipped to [0.8, 1.0) of 400px = 20%
        XCTAssertEqual(result.compositeSize.width, 80)
    }

    func test_emptySketch_compositeEqualsCrop() throws {
        let base = TestImages.leftRightCGImage(width: 200, height: 100, left: TestImages.RGBA(10, 20, 30), right: TestImages.RGBA(40, 50, 60))
        let zoomRect = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)

        let result = try Compositor.composite(base: base, sketchPNG: Data(), zoomRect: zoomRect)

        guard let cropped = base.cropping(to: CGRect(x: 0, y: 0, width: 100, height: 100)) else {
            return XCTFail("expected the crop to succeed")
        }
        let cropPNG = TestImages.pngData(cropped)

        for x in stride(from: 0, to: 100, by: 33) {
            for y in stride(from: 0, to: 100, by: 33) {
                assertColor(TestImages.pixel(inPNG: result.compositePNG, x: x, y: y), TestImages.pixel(inPNG: cropPNG, x: x, y: y) ?? TestImages.RGBA(0, 0, 0, 0))
            }
        }
    }

    func test_garbageSketch_throwsUndecodableSketch() {
        let base = TestImages.solidCGImage(width: 10, height: 10, color: TestImages.RGBA(1, 1, 1))
        let garbage = Data([0x00, 0x01, 0x02, 0x03])

        XCTAssertThrowsError(try Compositor.composite(base: base, sketchPNG: garbage, zoomRect: .full)) { error in
            XCTAssertEqual(error as? CompositorError, .undecodableSketch)
        }
    }

    func test_screenshotPNG_alwaysDecodesToFullBaseSize() throws {
        let base = TestImages.solidCGImage(width: 400, height: 300, color: TestImages.RGBA(5, 5, 5))
        let zoomRect = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)

        let result = try Compositor.composite(base: base, sketchPNG: Data(), zoomRect: zoomRect)

        guard let source = CGImageSourceCreateWithData(result.screenshotPNG as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("expected screenshotPNG to decode")
        }
        XCTAssertEqual(decoded.width, 400)
        XCTAssertEqual(decoded.height, 300)
    }

    func test_sketchPNG_isInputBytesUnchanged() throws {
        let base = TestImages.solidCGImage(width: 10, height: 10, color: TestImages.RGBA(1, 1, 1))
        let sketch = TestImages.rectOnTransparentCGImage(width: 10, height: 10, rect: CGRect(x: 0, y: 0, width: 5, height: 5), fill: TestImages.RGBA(255, 0, 0))
        let sketchPNG = TestImages.pngData(sketch)

        let result = try Compositor.composite(base: base, sketchPNG: sketchPNG, zoomRect: .full)
        XCTAssertEqual(result.sketchPNG, sketchPNG)

        let emptyResult = try Compositor.composite(base: base, sketchPNG: Data(), zoomRect: .full)
        XCTAssertEqual(emptyResult.sketchPNG, Data())
    }

    // MARK: - cgImage(from:)

    func test_cgImage_fromBGRAPixelBuffer() {
        let buffer = TestImages.solidBGRAPixelBuffer(width: 8, height: 8, color: TestImages.RGBA(12, 34, 56))

        guard let image = Compositor.cgImage(from: buffer) else {
            return XCTFail("expected a CGImage")
        }
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 8)
        assertColor(TestImages.pixel(in: image, x: 4, y: 4), TestImages.RGBA(12, 34, 56))
    }

    func test_cgImage_fromNV12PixelBuffer() {
        let buffer = TestImages.solidNV12PixelBuffer(width: 8, height: 8, gray: 128)

        guard let image = Compositor.cgImage(from: buffer) else {
            return XCTFail("expected a CGImage")
        }
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 8)
        assertColor(TestImages.pixel(in: image, x: 4, y: 4), TestImages.RGBA(128, 128, 128), tolerance: 4)
    }

    // MARK: - Helpers

    private func assertColor(
        _ actual: TestImages.RGBA?,
        _ expected: TestImages.RGBA,
        tolerance: Int = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("expected a pixel, got nil", file: file, line: line)
            return
        }
        func close(_ a: UInt8, _ b: UInt8) -> Bool { abs(Int(a) - Int(b)) <= tolerance }
        XCTAssertTrue(
            close(actual.r, expected.r) && close(actual.g, expected.g) && close(actual.b, expected.b) && close(actual.a, expected.a),
            "expected \(expected), got \(actual)",
            file: file,
            line: line
        )
    }
}
