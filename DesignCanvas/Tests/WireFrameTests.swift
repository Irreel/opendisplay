import XCTest

/// The framing both apps put on the socket (spec/wire-protocol.md sections 2
/// and 3): every frame says what it is, and a message carries binary as
/// itself.
final class WireFrameTests: XCTestCase {

    private func readAll(_ bytes: Data, chunk: Int = .max) throws -> [RawFrame] {
        var reader = FrameReader()
        var frames: [RawFrame] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + chunk)
            reader.append(bytes.subdata(in: offset..<end))
            offset = end
            while let frame = try reader.next() { frames.append(frame) }
        }
        return frames
    }

    func test_aMessageRoundTripsWithItsTypeAndFields() throws {
        let frame = try XCTUnwrap(WireCodec.message("status", ["channel": "attached", "project": "site"]))
        let frames = try readAll(frame)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, FrameKind.message.rawValue)
        let message = try WireCodec.message(from: frames[0].body)
        XCTAssertEqual(message.type, "status")
        XCTAssertEqual(message.object["channel"] as? String, "attached")
        XCTAssertEqual(message.object["project"] as? String, "site")
        XCTAssertTrue(message.attachment.isEmpty)
    }

    func test_anAttachmentArrivesByteForByte_evenOneByteAtATime() throws {
        // Every byte value, so a NUL or a `{` inside the binary changes nothing.
        let png = Data((0..<4096).map { UInt8($0 % 256) })
        let frame = try XCTUnwrap(WireCodec.message("annotation", ["t": 1.5], attachment: png))
        let frames = try readAll(frame, chunk: 1)
        XCTAssertEqual(frames.count, 1)
        let message = try WireCodec.message(from: frames[0].body)
        XCTAssertEqual(message.type, "annotation")
        XCTAssertEqual(message.attachment, png)
    }

    func test_severalFramesInOneChunkComeOutInOrder() throws {
        var bytes = Data()
        bytes.append(try XCTUnwrap(WireCodec.message("ping", ["t": 1])))
        bytes.append(WireCodec.video(VideoPacket(frame: 7, isKeyframe: false, sample: Data([0, 0, 0, 1, 0x41]))))
        bytes.append(try XCTUnwrap(WireCodec.message("pong", ["t": 1])))
        let frames = try readAll(bytes)
        XCTAssertEqual(frames.map(\.kind), [FrameKind.message.rawValue, FrameKind.video.rawValue, FrameKind.message.rawValue])
        XCTAssertEqual(try WireCodec.message(from: frames[2].body).type, "pong")
        XCTAssertEqual(try VideoPacket(body: frames[1].body).frame, 7)
    }

    func test_aPartialFrameWaitsForTheRest() throws {
        let frame = try XCTUnwrap(WireCodec.message("hello", ["v": 1, "role": "mac"]))
        var reader = FrameReader()
        reader.append(frame.prefix(frame.count - 1))
        XCTAssertNil(try reader.next())
        XCTAssertEqual(reader.pendingByteCount, frame.count - 1)
        reader.append(frame.suffix(1))
        XCTAssertNotNil(try reader.next())
        XCTAssertEqual(reader.pendingByteCount, 0)
    }

    func test_aZeroLengthFrameIsRejected_becauseTheNextBoundaryIsUnknown() {
        var reader = FrameReader()
        reader.append(Data([0, 0, 0, 0, 1]))
        XCTAssertThrowsError(try reader.next()) { error in
            XCTAssertEqual(error as? WireError, .badFrameLength(0))
        }
    }

    func test_aLengthOverTheCapIsRejectedBeforeAnyBodyArrives() {
        var reader = FrameReader()
        var header = Data()
        header.appendBigEndian(UInt32(CanvasWire.maxFrameLength + 1))
        reader.append(header)
        XCTAssertThrowsError(try reader.next())
    }

    /// The old OpenDisplay-based wire put JSON straight after the length. It
    /// still parses as a frame — of a kind nobody knows — so a peer running
    /// the old app is noticed rather than misread.
    func test_theOldWiresJSONReadsAsAnUnknownKind() throws {
        let json = Data(#"{"type":"ping","t":1}"#.utf8)
        var bytes = Data()
        bytes.appendBigEndian(UInt32(json.count))
        bytes.append(json)
        let frames = try readAll(bytes)
        XCTAssertEqual(frames.first?.kind, UInt8(ascii: "{"))
        XCTAssertNil(FrameKind(rawValue: frames[0].kind))
    }

    func test_aMessageThatCannotBeSerialisedIsRefused() {
        XCTAssertNil(WireCodec.message("bad", ["value": Double.nan]))
        XCTAssertNil(WireCodec.message("bad", ["date": Date()]))
    }

    func test_aMessageOverTheFrameCapIsRefusedAtTheSender() {
        let tooBig = Data(count: CanvasWire.maxFrameLength)
        XCTAssertNil(WireCodec.message("annotation", [:], attachment: tooBig))
    }

    func test_aMessageWithoutATypeIsBadJSON() {
        var body = Data()
        let json = Data(#"{"t":1}"#.utf8)
        body.appendBigEndian(UInt32(json.count))
        body.append(json)
        XCTAssertThrowsError(try WireCodec.message(from: body)) { error in
            XCTAssertEqual(error as? WireError, .badJSON)
        }
    }

    func test_aJSONLengthPastTheEndOfTheFrameIsBadLayout() {
        var body = Data()
        body.appendBigEndian(UInt32(100))
        body.append(Data(#"{"type":"x"}"#.utf8))
        XCTAssertThrowsError(try WireCodec.message(from: body)) { error in
            XCTAssertEqual(error as? WireError, .badMessageLayout)
        }
    }

    func test_theReaderKeepsWorkingAcrossManyFrames() throws {
        // Enough frames that the lazy compaction runs several times.
        var reader = FrameReader()
        let frame = try XCTUnwrap(WireCodec.message("ping", ["t": 1], attachment: Data(count: 1000)))
        var seen = 0
        for _ in 0..<500 {
            reader.append(frame.prefix(600))
            reader.append(frame.dropFirst(600))
            while try reader.next() != nil { seen += 1 }
        }
        XCTAssertEqual(seen, 500)
        XCTAssertEqual(reader.pendingByteCount, 0)
    }
}
