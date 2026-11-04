// One encoded video frame as it crosses the wire (spec/wire-protocol.md,
// section 4):
//
//     [u64 BE frame number][u8 flags]
//     [flags & hasParameterSets: u8 count, then count × (u16 BE length, bytes)]
//     [sample: the encoder's own AVCC output, (u32 BE length, NAL unit)…]
//
// The sample is sent exactly as VideoToolbox emits it and is exactly what
// CoreMedia wants on the other side, so neither end rewrites NAL units into
// Annex B and back. The frame number is the capture's, and is what a
// `freeze` names: the Mac keeps the clean original under the same number.

import Foundation

struct VideoPacket: Equatable {
    /// The capture's frame number. Strictly increasing on one link, but not
    /// contiguous: frames the link had no room for are never encoded.
    var frame: UInt64
    /// A sync sample: decodable without anything before it.
    var isKeyframe: Bool
    /// The decoder configuration (H.264: SPS then PPS). Sent with every
    /// keyframe; empty otherwise.
    var parameterSets: [Data]
    /// Length-prefixed NAL units, 4-byte big-endian lengths.
    var sample: Data

    private static let keyframeFlag: UInt8 = 0x01
    private static let parameterSetsFlag: UInt8 = 0x02

    func encoded() -> Data {
        var out = Data(capacity: 10 + parameterSets.reduce(0) { $0 + 2 + $1.count } + sample.count)
        out.appendBigEndian(frame)
        var flags: UInt8 = isKeyframe ? Self.keyframeFlag : 0
        if !parameterSets.isEmpty { flags |= Self.parameterSetsFlag }
        out.append(flags)
        if !parameterSets.isEmpty {
            out.append(UInt8(clamping: parameterSets.count))
            for set in parameterSets.prefix(255) {
                out.appendBigEndian(UInt16(clamping: set.count))
                out.append(set.prefix(Int(UInt16.max)))
            }
        }
        out.append(sample)
        return out
    }

    init(frame: UInt64, isKeyframe: Bool, parameterSets: [Data] = [], sample: Data) {
        self.frame = frame
        self.isKeyframe = isKeyframe
        self.parameterSets = parameterSets
        self.sample = sample
    }

    /// Parses a video frame's body. Throws on a layout that runs off the end.
    init(body: Data) throws {
        guard body.count >= 9 else { throw WireError.badVideoLayout }
        frame = body.readBigEndianUInt64(at: 0)
        let flags = body[body.startIndex + 8]
        isKeyframe = flags & Self.keyframeFlag != 0
        var offset = 9
        var sets: [Data] = []
        if flags & Self.parameterSetsFlag != 0 {
            guard body.count >= offset + 1 else { throw WireError.badVideoLayout }
            let count = Int(body[body.startIndex + offset])
            offset += 1
            for _ in 0..<count {
                guard body.count >= offset + 2 else { throw WireError.badVideoLayout }
                let length = Int(body.readBigEndianUInt16(at: offset))
                offset += 2
                guard body.count >= offset + length else { throw WireError.badVideoLayout }
                let start = body.startIndex + offset
                sets.append(Data(body[start..<(start + length)]))
                offset += length
            }
        }
        parameterSets = sets
        sample = Data(body[(body.startIndex + offset)...])
    }

    /// True when `sample` is a well-formed run of length-prefixed NAL units
    /// with at least one in it. The receiver checks before handing bytes to
    /// the decoder, which does not take kindly to a length that lies.
    var sampleIsWellFormed: Bool {
        var offset = 0
        var units = 0
        while offset < sample.count {
            guard sample.count - offset >= 4 else { return false }
            let length = Int(sample.readBigEndianUInt32(at: offset))
            guard length > 0, sample.count - offset - 4 >= length else { return false }
            offset += 4 + length
            units += 1
        }
        return units > 0
    }
}
