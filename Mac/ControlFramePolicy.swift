import Foundation

/// Decides what to do with a receiver-to-sender control frame once its
/// 4-byte length header has arrived, and guards what we send back.
///
/// PROTOCOL.md section 3 caps a receiver-to-sender payload at `1 ..< 2^20`
/// bytes; a Design Canvas session raises that to 16 MiB so a sketch fits in
/// one frame. Either way the payload is read in `chunkSize` pieces rather
/// than one `receive(minimumIncompleteLength:)` for the whole thing, so the
/// read loop can refresh the liveness timestamp while a large upload is
/// still in flight and the 5 s watchdog does not redial underneath it.
///
/// The policy is a pure value type: it never touches a connection and makes
/// every decision the read loop has to make, which is what keeps that loop
/// (untestable without a live `NWConnection`) a thin executor of `Decision`.
struct ControlFramePolicy: Equatable {
    /// PROTOCOL.md section 3: the wire cap for a plain OpenDisplay session.
    static let standardCap = 1 << 20          // 1 MiB
    /// A Design Canvas sketch may be this large (plan: exact values).
    static let canvasCap = 16 << 20           // 16 MiB
    /// One socket read's worth of payload.
    static let chunkSize = 256 << 10          // 256 KiB
    /// PROTOCOL.md section 4: a sender-to-receiver control message must be
    /// shorter than this or the receiver's demux heuristic reads it as video.
    static let outboundJSONLimit = 32768

    /// Declared length must be in `1 ..< cap`.
    let cap: Int

    enum Decision: Equatable {
        /// Read the payload as these chunk sizes, in order.
        case read(chunks: [Int])
        case reject(reason: String)
    }

    init(canvas: Bool) {
        cap = canvas ? Self.canvasCap : Self.standardCap
    }

    /// `length <= 0` or `>= cap` rejects; otherwise the chunk sizes that sum
    /// to `length`, each at most `chunkSize`, with only the last smaller.
    func decide(declaredLength length: Int) -> Decision {
        guard length > 0 else { return .reject(reason: "empty frame") }
        guard length < cap else { return .reject(reason: "frame exceeds \(cap)-byte cap") }
        var chunks: [Int] = []
        chunks.reserveCapacity((length + Self.chunkSize - 1) / Self.chunkSize)
        var remaining = length
        while remaining > 0 {
            let chunk = min(remaining, Self.chunkSize)
            chunks.append(chunk)
            remaining -= chunk
        }
        return .read(chunks: chunks)
    }

    /// True iff `0 < byteCount < outboundJSONLimit`.
    static func allowsOutboundJSON(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount < outboundJSONLimit
    }

    /// The bytes to put on the wire for an outbound control object, or nil
    /// when it cannot go: `JSONSerialization` will not represent it (a Date,
    /// a NaN), or its encoding breaks the limit above.
    ///
    /// This is everything a caller can decide about a message on its own —
    /// whether the link is up is the sending queue's business, not the
    /// message's — so it is the whole synchronous answer to "can this be
    /// sent", and it is pure.
    static func outboundJSONPayload(for object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              let payload = try? JSONSerialization.data(withJSONObject: object),
              allowsOutboundJSON(byteCount: payload.count) else { return nil }
        return payload
    }
}
