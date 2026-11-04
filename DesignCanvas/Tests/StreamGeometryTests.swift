import XCTest

/// The stream size: the display's own, unless the encoder cannot take it.
final class StreamGeometryTests: XCTestCase {

    private func assertEncodable(_ size: (width: Int, height: Int), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(StreamGeometry.macroblocks(size.width, size.height), StreamGeometry.maxMacroblocks,
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(max(size.width, size.height), StreamGeometry.maxSide, file: file, line: line)
        XCTAssertEqual(size.width % 2, 0, file: file, line: line)
        XCTAssertEqual(size.height % 2, 0, file: file, line: line)
    }

    func test_aRetinaLaptopStreamsAtItsOwnSize() {
        let size = StreamGeometry.streamSize(pixelWidth: 3024, pixelHeight: 1964, scale: 1)
        XCTAssertEqual(size.width, 3024)
        XCTAssertEqual(size.height, 1964)
    }

    /// A 5K display at full size used to be rejected by the encoder frame
    /// after frame. It now streams at the largest size H.264 takes.
    func test_a5KDisplayIsScaledToFitTheEncoder_keepingItsShape() {
        let size = StreamGeometry.streamSize(pixelWidth: 5120, pixelHeight: 2880, scale: 1)
        assertEncodable(size)
        XCTAssertEqual(Double(size.width) / Double(size.height), 16.0 / 9.0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(size.width, 4000)
    }

    func test_theQualityScaleApplies() {
        let size = StreamGeometry.streamSize(pixelWidth: 2560, pixelHeight: 1600, scale: 0.5)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 800)
    }

    func test_anUltrawideIsHeldToTheLongestSide() {
        let size = StreamGeometry.streamSize(pixelWidth: 6880, pixelHeight: 2880, scale: 1)
        assertEncodable(size)
        XCTAssertEqual(Double(size.width) / Double(size.height), 6880.0 / 2880.0, accuracy: 0.02)
    }

    func test_oddSizesComeOutEven() {
        assertEncodable(StreamGeometry.streamSize(pixelWidth: 1367, pixelHeight: 769, scale: 1))
    }

    func test_nonsenseInputStillGivesAnEncodableSize() {
        assertEncodable(StreamGeometry.streamSize(pixelWidth: 0, pixelHeight: 0, scale: 1))
        assertEncodable(StreamGeometry.streamSize(pixelWidth: 1920, pixelHeight: 1080, scale: .nan))
        assertEncodable(StreamGeometry.streamSize(pixelWidth: 1920, pixelHeight: 1080, scale: 7))
    }
}
