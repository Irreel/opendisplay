import XCTest

final class ControlFramePolicyTests: XCTestCase {
    private let policy = ControlFramePolicy()

    // MARK: - Caps

    func testCapIsOneMebibyte() {
        XCTAssertEqual(policy.cap, 1 << 20)
        XCTAssertEqual(ControlFramePolicy.standardCap, 1_048_576)
        XCTAssertEqual(ControlFramePolicy.chunkSize, 262_144)
        XCTAssertEqual(ControlFramePolicy.outboundJSONLimit, 32_768)
    }

    func testEmptyAndNegativeLengthsAreRejected() {
        guard case .reject = policy.decide(declaredLength: 0) else {
            return XCTFail("length 0 must be rejected")
        }
        guard case .reject = policy.decide(declaredLength: -1) else {
            return XCTFail("length -1 must be rejected")
        }
    }

    func testOneBelowTheCapIsAcceptedAndTheCapItselfIsRejected() {
        guard case .read(let chunks) = policy.decide(declaredLength: policy.cap - 1) else {
            return XCTFail("cap - 1 must be accepted")
        }
        XCTAssertEqual(chunks.reduce(0, +), policy.cap - 1)
        guard case .reject = policy.decide(declaredLength: policy.cap) else {
            return XCTFail("cap \(policy.cap) must be rejected")
        }
    }

    // MARK: - Chunk plans

    func testOneByteFrameIsOneOneByteChunk() {
        XCTAssertEqual(policy.decide(declaredLength: 1), .read(chunks: [1]))
    }

    func testExactlyOneChunkSizeIsASingleChunk() {
        XCTAssertEqual(policy.decide(declaredLength: 262_144),
                       .read(chunks: [262_144]))
    }

    func testOneByteOverAChunkSizeIsTwoChunks() {
        XCTAssertEqual(policy.decide(declaredLength: 262_145),
                       .read(chunks: [262_144, 1]))
    }

    func testLargestFrameChunksSumToTheLengthAndNoneExceedsTheChunkSize() {
        let length = ControlFramePolicy.standardCap - 1
        guard case .read(let chunks) = policy.decide(declaredLength: length) else {
            return XCTFail("\(length) must be accepted")
        }
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks.reduce(0, +), length)
        XCTAssertTrue(chunks.allSatisfy { $0 > 0 && $0 <= ControlFramePolicy.chunkSize })
    }

    // MARK: - Outbound JSON guard

    func testAllowsOutboundJSONOnlyStrictlyBetweenZeroAndTheLimit() {
        XCTAssertFalse(ControlFramePolicy.allowsOutboundJSON(byteCount: 0))
        XCTAssertTrue(ControlFramePolicy.allowsOutboundJSON(byteCount: 1))
        XCTAssertTrue(ControlFramePolicy.allowsOutboundJSON(byteCount: 32_767))
        XCTAssertFalse(ControlFramePolicy.allowsOutboundJSON(byteCount: 32_768))
    }
}
