// The seams MacSender exposes so a Design Canvas session can reuse it.
//
// Two things separate a canvas session from an OpenDisplay one: it forwards
// no input (no Accessibility, so `Mac/InputInjector.swift` is not even
// compiled into that app), and it needs to see each captured frame and each
// canvas control message. Both arrive here as protocols MacSender depends on
// instead of concrete types, so injecting nothing leaves OpenDisplay exactly
// as it was.
//
// Foundation + CoreVideo + CoreGraphics only, and no reference to MacSender
// or to any Design Canvas type: this file is compiled into hostless test
// bundles on both sides.

import Foundation
import CoreVideo
import CoreGraphics

/// What MacSender needs from an input injector. `InputInjector` conforms;
/// Design Canvas passes none, which is what makes the input path dead code
/// there rather than a permission it has to ask for.
protocol InputSink: AnyObject {
    func handleTouch(phase: String, x: Double, y: Double)
    func handleScroll(dx: Double, dy: Double)
    func handlePencil(phase: String, x: Double, y: Double, pressure: Double,
                      azimuth: Double, altitude: Double, rotation: Double)
    func handleProximity(entering: Bool, x: Double, y: Double)
}

/// Builds the sink for a display the sender just created. Called again after
/// a rotation rebuild, so it must be safe to invoke more than once per
/// session.
typealias InputSinkFactory = (CGDirectDisplayID) -> InputSink?

/// The sender side a canvas delegate may talk back to. `MacSender` conforms.
protocol CanvasOutbound: AnyObject {
    /// Serialises and sends on the sender's queue. Returns false (and logs)
    /// if not connected, not serialisable, or the payload breaks the
    /// 32768-byte rule (PROTOCOL.md section 4).
    @discardableResult func sendCanvasJSON(_ object: [String: Any]) -> Bool
    /// Same, for bytes already encoded (used for the size-fitted rounds
    /// snapshot, which is shrunk to fit before it is handed over).
    @discardableResult func sendCanvasJSONData(_ data: Data) -> Bool
}

/// The receiver on the other end of a canvas session, as the delegate needs
/// to know it.
struct CanvasPeer: Equatable {
    let installID: String
    let deviceKind: String
}

/// All callbacks arrive on the sender's serial queue — the same queue the
/// control reads and the capture callbacks run on. Implementations must
/// return quickly: blocking here stalls video, and the frame callback fires
/// at capture rate.
protocol SenderCanvasDelegate: AnyObject {
    /// After `welcome` was sent, on every hello including rotation re-hellos.
    func canvasPeerDidHello(_ peer: CanvasPeer, outbound: CanvasOutbound)
    /// One captured frame, with the same millisecond the frame carries to the
    /// receiver as its `cap` telemetry — that is what pairs a freeze request
    /// with the clean frame it named.
    func canvasDidEncodeFrame(_ pixelBuffer: CVPixelBuffer, captureMs: Int64)
    /// An inbound canvas control message (`freeze`, `annotation`), already
    /// parsed. Unknown-to-canvas types never reach here.
    func canvasDidReceive(type: String, object: [String: Any], outbound: CanvasOutbound)
    /// The link is gone (dropped, declared gone, or the sender stopped). May
    /// arrive more than once for one drop, so implementations are idempotent.
    func canvasLinkDidDrop()
    /// Extra string fields to merge into the sender's outbound `ping`, e.g.
    /// `["channel": "attached", "project": "site"]`.
    func canvasPingFields() -> [String: String]
}

/// The sender's `welcome` and `ping` control messages.
///
/// These strings are the wire (PROTOCOL.md section 6.2) and predate this
/// file; they are built by interpolation rather than `JSONSerialization` so
/// the output stays byte-identical to what every receiver in the field
/// already parses — key order included. With `canvas: false` and no extras
/// that is exactly the string MacSender used to interpolate inline.
enum SenderControlJSON {
    /// Fields `ping` builds itself. An extra that collides with one is
    /// dropped: a delegate must not be able to restate the sender's own
    /// health counters, and a duplicate key is undefined for JSON readers.
    private static let reservedPingKeys: Set<String> = [
        "type", "drops", "encDrops", "netDrops", "pending", "inp50", "inp95", "capFps",
    ]

    /// The version handshake reply (PROTOCOL.md section 10). `canvas` is the
    /// Design Canvas capability gate and is present only when true, so an
    /// OpenDisplay session's bytes are unchanged.
    static func welcome(pv: Int, min: Int, canvas: Bool) -> String {
        canvas
            ? "{\"type\":\"welcome\",\"pv\":\(pv),\"min\":\(min),\"canvas\":true}"
            : "{\"type\":\"welcome\",\"pv\":\(pv),\"min\":\(min)}"
    }

    /// The liveness beat plus send-side health. `inp50`/`inp95` are Doubles
    /// because the sender rounds percentiles rather than truncating them —
    /// they reach the wire as `12.0`, and receivers parse them as numbers.
    /// `extras` are appended in sorted key order so the output is
    /// deterministic whatever order the delegate's dictionary iterates in.
    static func ping(drops: Int, encDrops: Int, netDrops: Int, pending: Int,
                     inp50: Double, inp95: Double, capFps: Int,
                     extras: [String: String]) -> String {
        var json = "{\"type\":\"ping\",\"drops\":\(drops),\"encDrops\":\(encDrops),\"netDrops\":\(netDrops),\"pending\":\(pending),\"inp50\":\(inp50),\"inp95\":\(inp95),\"capFps\":\(capFps)"
        for key in extras.keys.sorted() where !reservedPingKeys.contains(key) {
            guard let value = extras[key] else { continue }
            json += ",\(quoted(key)):\(quoted(value))"
        }
        return json + "}"
    }

    /// A JSON string literal. Extras carry user-shaped text (a project name,
    /// a channel state), so the quoting has to be real: a bare quote,
    /// backslash or newline would otherwise put an unparseable message on the
    /// wire, and the receiver ignores what it cannot parse.
    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
