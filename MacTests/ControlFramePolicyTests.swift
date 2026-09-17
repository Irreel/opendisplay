import XCTest

final class ControlFramePolicyTests: XCTestCase {
    private let standardPolicy = ControlFramePolicy(canvas: false)
    private let canvasPolicy = ControlFramePolicy(canvas: true)

    // MARK: - Caps

    func testCapIsOneMebibyteWithoutCanvasAndSixteenWithIt() {
        XCTAssertEqual(standardPolicy.cap, 1 << 20)
        XCTAssertEqual(canvasPolicy.cap, 16 << 20)
        XCTAssertEqual(ControlFramePolicy.standardCap, 1_048_576)
        XCTAssertEqual(ControlFramePolicy.canvasCap, 16_777_216)
        XCTAssertEqual(ControlFramePolicy.chunkSize, 262_144)
        XCTAssertEqual(ControlFramePolicy.outboundJSONLimit, 32_768)
    }

    func testEmptyAndNegativeLengthsAreRejected() {
        for policy in [standardPolicy, canvasPolicy] {
            guard case .reject = policy.decide(declaredLength: 0) else {
                return XCTFail("length 0 must be rejected")
            }
            guard case .reject = policy.decide(declaredLength: -1) else {
                return XCTFail("length -1 must be rejected")
            }
        }
    }

    func testOneBelowTheCapIsAcceptedAndTheCapItselfIsRejectedInBothModes() {
        for policy in [standardPolicy, canvasPolicy] {
            guard case .read(let chunks) = policy.decide(declaredLength: policy.cap - 1) else {
                return XCTFail("cap - 1 must be accepted for cap \(policy.cap)")
            }
            XCTAssertEqual(chunks.reduce(0, +), policy.cap - 1)
            guard case .reject = policy.decide(declaredLength: policy.cap) else {
                return XCTFail("cap \(policy.cap) must be rejected")
            }
        }
    }

    // MARK: - Chunk plans

    func testOneByteFrameIsOneOneByteChunk() {
        XCTAssertEqual(standardPolicy.decide(declaredLength: 1), .read(chunks: [1]))
    }

    func testExactlyOneChunkSizeIsASingleChunk() {
        XCTAssertEqual(standardPolicy.decide(declaredLength: 262_144),
                       .read(chunks: [262_144]))
    }

    func testOneByteOverAChunkSizeIsTwoChunks() {
        XCTAssertEqual(standardPolicy.decide(declaredLength: 262_145),
                       .read(chunks: [262_144, 1]))
    }

    func testLargestStandardFrameChunksSumToTheLengthAndNoneExceedsTheChunkSize() {
        let length = ControlFramePolicy.standardCap - 1
        guard case .read(let chunks) = standardPolicy.decide(declaredLength: length) else {
            return XCTFail("\(length) must be accepted")
        }
        XCTAssertEqual(chunks.reduce(0, +), length)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0 > 0 && $0 <= ControlFramePolicy.chunkSize })
    }

    func testLargestCanvasFrameYieldsSixtyFourChunks() {
        let length = ControlFramePolicy.canvasCap - 1
        guard case .read(let chunks) = canvasPolicy.decide(declaredLength: length) else {
            return XCTFail("\(length) must be accepted in canvas mode")
        }
        XCTAssertEqual(chunks.count, 64)
        XCTAssertEqual(chunks.reduce(0, +), length)
        XCTAssertTrue(chunks.allSatisfy { $0 > 0 && $0 <= ControlFramePolicy.chunkSize })
    }

    func testCanvasCapAcceptsWhatTheStandardCapRejects() {
        let length = ControlFramePolicy.standardCap
        guard case .reject = standardPolicy.decide(declaredLength: length) else {
            return XCTFail("\(length) must be rejected without canvas")
        }
        guard case .read = canvasPolicy.decide(declaredLength: length) else {
            return XCTFail("\(length) must be accepted with canvas")
        }
    }

    // MARK: - Outbound JSON guard

    func testAllowsOutboundJSONOnlyStrictlyBetweenZeroAndTheLimit() {
        XCTAssertFalse(ControlFramePolicy.allowsOutboundJSON(byteCount: 0))
        XCTAssertTrue(ControlFramePolicy.allowsOutboundJSON(byteCount: 1))
        XCTAssertTrue(ControlFramePolicy.allowsOutboundJSON(byteCount: 32_767))
        XCTAssertFalse(ControlFramePolicy.allowsOutboundJSON(byteCount: 32_768))
    }

    // MARK: - Outbound payloads

    func testOutboundJSONPayloadRoundTripsASendableObject() throws {
        let payload = try XCTUnwrap(
            ControlFramePolicy.outboundJSONPayload(for: ["type": "frozen", "ok": true]))
        XCTAssertTrue(ControlFramePolicy.allowsOutboundJSON(byteCount: payload.count))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "frozen")
        XCTAssertEqual(object["ok"] as? Bool, true)
    }

    func testOutboundJSONPayloadRefusesAnObjectJSONCannotRepresent() {
        XCTAssertNil(ControlFramePolicy.outboundJSONPayload(for: ["at": Date()]))
        XCTAssertNil(ControlFramePolicy.outboundJSONPayload(for: ["ratio": Double.nan]))
    }

    func testOutboundJSONPayloadRefusesAnObjectThatReachesTheLimit() {
        // The value alone already passes the limit, so no encoding of this
        // object can fit — the caller must not get bytes it cannot send.
        let oversize = String(repeating: "x", count: ControlFramePolicy.outboundJSONLimit)
        XCTAssertNil(ControlFramePolicy.outboundJSONPayload(for: ["note": oversize]))
    }
}
