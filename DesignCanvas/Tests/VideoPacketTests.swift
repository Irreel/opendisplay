import XCTest

/// One encoded frame on the wire (spec/wire-protocol.md section 4).
final class VideoPacketTests: XCTestCase {

    /// Two NAL units, length-prefixed the way VideoToolbox emits them.
    private let sample = Data([0, 0, 0, 3, 0x65, 0xAA, 0xBB, 0, 0, 0, 2, 0x41, 0xCC])

    func test_aKeyframeRoundTripsWithItsParameterSets() throws {
        let sps = Data([0x67, 0x64, 0x00, 0x28])
        let pps = Data([0x68, 0xEE, 0x3C, 0x80])
        let packet = VideoPacket(frame: 1_234_567_890_123, isKeyframe: true, parameterSets: [sps, pps], sample: sample)
        let decoded = try VideoPacket(body: packet.encoded())
        XCTAssertEqual(decoded, packet)
    }

    func test_aDeltaFrameCarriesNoParameterSets() throws {
        let packet = VideoPacket(frame: 42, isKeyframe: false, sample: sample)
        let body = packet.encoded()
        // 8 bytes of frame number, 1 of flags, then the sample itself.
        XCTAssertEqual(body.count, 9 + sample.count)
        XCTAssertEqual(try VideoPacket(body: body), packet)
    }

    func test_aTruncatedParameterSetThrows() {
        let packet = VideoPacket(frame: 1, isKeyframe: true, parameterSets: [Data(count: 10)], sample: sample)
        let body = packet.encoded()
        XCTAssertThrowsError(try VideoPacket(body: body.prefix(14)))
    }

    func test_aBodyShorterThanTheHeaderThrows() {
        XCTAssertThrowsError(try VideoPacket(body: Data(count: 8)))
    }

    func test_wellFormedSamplesAreRecognised() {
        XCTAssertTrue(VideoPacket(frame: 1, isKeyframe: false, sample: sample).sampleIsWellFormed)
    }

    func test_aSampleWhoseLengthLiesIsNotWellFormed() {
        XCTAssertFalse(VideoPacket(frame: 1, isKeyframe: false, sample: Data([0, 0, 0, 9, 0x41])).sampleIsWellFormed)
        XCTAssertFalse(VideoPacket(frame: 1, isKeyframe: false, sample: Data([0, 0, 0, 0])).sampleIsWellFormed)
        XCTAssertFalse(VideoPacket(frame: 1, isKeyframe: false, sample: Data([0, 0])).sampleIsWellFormed)
        XCTAssertFalse(VideoPacket(frame: 1, isKeyframe: false, sample: Data()).sampleIsWellFormed)
    }
}
