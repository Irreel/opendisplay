// The Design Canvas wire: how bytes on the Mac-iPad socket become frames and
// back (spec/wire-protocol.md, sections 2 and 3).
//
//     frame   = [u32 BE length][u8 kind][length - 1 bytes of body]
//     message = body of kind 1: [u32 BE json length][JSON object][attachment]
//     video   = body of kind 2: see VideoPacket
//
// Every frame says what it is, so nothing is ever told apart by guessing at
// its bytes, and a message can carry binary (a sketch PNG) without base64.
//
// Foundation only: compiled into both apps and the hostless test bundle.

import Foundation

enum FrameKind: UInt8 {
    case message = 1
    case video = 2
}

/// One frame off the wire, before its body is interpreted.
struct RawFrame: Equatable {
    var kind: UInt8
    var body: Data
}

/// A message: a JSON object with a `type`, and optionally bytes riding with it.
struct WireMessage {
    var type: String
    var object: [String: Any]
    var attachment: Data

    init(type: String, object: [String: Any], attachment: Data = Data()) {
        self.type = type
        self.object = object
        self.attachment = attachment
    }
}

enum WireError: Error, Equatable {
    /// A declared frame length of zero or above `CanvasWire.maxFrameLength`. The
    /// next frame's boundary is unknown after this, so the link must close.
    case badFrameLength(Int)
    /// A message frame whose JSON length runs past the frame, or is too big.
    case badMessageLayout
    /// The JSON was not an object with a string `type`.
    case badJSON
    case badVideoLayout
}

enum WireCodec {

    // MARK: - Encoding

    /// The frame for a message, or nil when the object cannot be serialised or
    /// the frame would break the size limits. `object` must not carry `type`;
    /// it is added here so every message has one.
    static func message(_ type: String, _ object: [String: Any] = [:],
                        attachment: Data = Data()) -> Data? {
        var body = object
        body["type"] = type
        guard JSONSerialization.isValidJSONObject(body),
              let json = try? JSONSerialization.data(withJSONObject: body),
              json.count <= CanvasWire.maxJSONLength else { return nil }
        let length = 1 + 4 + json.count + attachment.count
        guard length <= CanvasWire.maxFrameLength else { return nil }
        var frame = Data(capacity: 4 + length)
        frame.appendBigEndian(UInt32(length))
        frame.append(FrameKind.message.rawValue)
        frame.appendBigEndian(UInt32(json.count))
        frame.append(json)
        frame.append(attachment)
        return frame
    }

    static func video(_ packet: VideoPacket) -> Data {
        let body = packet.encoded()
        var frame = Data(capacity: 5 + body.count)
        frame.appendBigEndian(UInt32(1 + body.count))
        frame.append(FrameKind.video.rawValue)
        frame.append(body)
        return frame
    }

    // MARK: - Decoding

    static func message(from body: Data) throws -> WireMessage {
        guard body.count >= 4 else { throw WireError.badMessageLayout }
        let jsonLength = Int(body.readBigEndianUInt32(at: 0))
        guard jsonLength <= CanvasWire.maxJSONLength, 4 + jsonLength <= body.count else {
            throw WireError.badMessageLayout
        }
        let start = body.startIndex
        let json = body[(start + 4)..<(start + 4 + jsonLength)]
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let type = object["type"] as? String, !type.isEmpty else {
            throw WireError.badJSON
        }
        let attachment = Data(body[(start + 4 + jsonLength)...])
        return WireMessage(type: type, object: object, attachment: attachment)
    }
}

/// Turns arbitrary chunks of a byte stream back into frames. Not thread-safe:
/// owned by the one queue that reads the socket.
struct FrameReader {
    private var buffer = Data()
    /// Bytes at the front of `buffer` that were already handed out. Compacted
    /// lazily, so a burst of small frames costs one copy rather than one each.
    private var consumed = 0

    /// Bytes received and not yet returned as a frame.
    var pendingByteCount: Int { buffer.count - consumed }

    mutating func append(_ chunk: Data) {
        if consumed > 0, consumed >= buffer.count / 2 {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + consumed))
            consumed = 0
        }
        buffer.append(chunk)
    }

    /// The next whole frame, or nil when more bytes are needed. Throws on a
    /// declared length that cannot be right; the stream is unusable after.
    mutating func next() throws -> RawFrame? {
        guard pendingByteCount >= 4 else { return nil }
        let length = Int(buffer.readBigEndianUInt32(at: consumed))
        guard length >= 1, length <= CanvasWire.maxFrameLength else {
            throw WireError.badFrameLength(length)
        }
        guard pendingByteCount >= 4 + length else { return nil }
        let kindIndex = buffer.startIndex + consumed + 4
        let kind = buffer[kindIndex]
        let body = Data(buffer[(kindIndex + 1)..<(kindIndex + length)])
        consumed += 4 + length
        if consumed == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            consumed = 0
        }
        return RawFrame(kind: kind, body: body)
    }
}

// MARK: - Byte helpers

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// `offset` counts from `startIndex`, so slices read like whole buffers.
    func readBigEndianUInt16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16
            | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        UInt64(readBigEndianUInt32(at: offset)) << 32 | UInt64(readBigEndianUInt32(at: offset + 4))
    }
}
