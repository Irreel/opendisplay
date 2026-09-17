import Foundation

/// Wire constants for the Design Canvas additions to the OpenDisplay
/// protocol (see PROTOCOL.md, section "Wire additions to OpenDisplay").
/// Additive JSON control messages, no `pv` bump, gated on `welcome.canvas: true`.
enum CanvasWire {
    static let freeze = "freeze"
    static let frozen = "frozen"
    static let annotation = "annotation"
    static let agentReply = "agentReply"
    static let rounds = "rounds"

    static let welcomeCanvasKey = "canvas"                 // welcome.canvas: true

    static let pingChannelKey = "channel"
    static let pingProjectKey = "project"

    static let senderJSONLimit = 32768                     // payload must be < this
    static let replyMessageMaxBytes = 2048
    static let roundsSnapshotLimit = 20
    static let shrunkTextMaxBytes = 256

    /// The most base64 an `annotation`'s `sketch` may be (M10). A canvas
    /// receiver-to-sender frame is capped at 16 MiB (PROTOCOL.md 11.4) and the
    /// rest of the message — the zoom rect, the viewport, the note — shares that
    /// budget, so the sketch is held a megabyte short of it. A sketch over the
    /// limit is refused on the iPad, where the designer still has it, rather
    /// than by the sender's frame guard, which used to look like a link loss and
    /// put the round into an endless resend.
    static let annotationSketchBase64MaxBytes = 15 * 1024 * 1024   // 15728640

    /// Base64's encoded length for `byteCount` raw bytes: four characters per
    /// three bytes, rounded up, which is what actually crosses the wire.
    static func base64Length(ofByteCount byteCount: Int) -> Int {
        (byteCount + 2) / 3 * 4
    }
}

// MARK: - Number parsing

// JSONSerialization always boxes a JSON number as NSNumber, whether the
// wire text used an integer or a fractional literal; a Swift Int/Double
// literal boxed directly into `Any` also bridges to NSNumber on Darwin.
// Reading through NSNumber lets either representation decode.
private func canvasDouble(_ any: Any?) -> Double? {
    (any as? NSNumber)?.doubleValue
}

private func canvasInt(_ any: Any?) -> Int? {
    (any as? NSNumber)?.intValue
}

private func canvasInt64(_ any: Any?) -> Int64? {
    (any as? NSNumber)?.int64Value
}

// MARK: - NormalizedRect

/// A rect in the unit square (origin top-left), used for the zoom region.
struct NormalizedRect: Equatable {
    var x, y, width, height: Double

    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    /// True when within 0.001 of `.full` on every field.
    var isFull: Bool {
        abs(x) <= 0.001 && abs(y) <= 0.001 && abs(width - 1) <= 0.001 && abs(height - 1) <= 0.001
    }

    /// Clamps into `[0, 1]`, enforcing a minimum size of 0.01 so the rect is
    /// never empty even given a zero, negative, or overflowing origin/size.
    func clamped() -> NormalizedRect {
        let w = min(max(width > 0 ? width : 0.01, 0.01), 1)
        let h = min(max(height > 0 ? height : 0.01, 0.01), 1)
        let nx = min(max(x, 0), 1 - w)
        let ny = min(max(y, 0), 1 - h)
        return NormalizedRect(x: nx, y: ny, width: w, height: h)
    }
}

extension NormalizedRect {
    /// `{"x", "y", "w", "h"}` numbers.
    init?(json: Any?) {
        guard let dict = json as? [String: Any],
              let x = canvasDouble(dict["x"]),
              let y = canvasDouble(dict["y"]),
              let w = canvasDouble(dict["w"]),
              let h = canvasDouble(dict["h"]) else { return nil }
        self.x = x
        self.y = y
        self.width = w
        self.height = h
    }

    var json: [String: Double] {
        ["x": x, "y": y, "w": width, "h": height]
    }
}

// MARK: - CanvasViewport

struct CanvasViewport: Equatable {
    var width: Int
    var height: Int
    var scale: Double
}

extension CanvasViewport {
    /// `{"w", "h", "scale"}`.
    init?(json: Any?) {
        guard let dict = json as? [String: Any],
              let width = canvasInt(dict["w"]),
              let height = canvasInt(dict["h"]),
              let scale = canvasDouble(dict["scale"]) else { return nil }
        self.width = width
        self.height = height
        self.scale = scale
    }

    var json: [String: Any] {
        ["w": width, "h": height, "scale": scale]
    }
}

// MARK: - Round / channel status enums

enum RoundStatus: String {
    case queued
    case sent
    case applied
    case failed
    case needsInput = "needs_input"

    /// How far along a round this status is, so a receiver can refuse to move a
    /// round backwards (M5). The Mac sends a snapshot after every hello and a
    /// live `agentReply` per change, and the two race: a snapshot built before
    /// a reply landed must not turn "applied, with a message" back into
    /// "queued". The three outcomes share a rank — which one a round ends in is
    /// not progress, so a reply may still correct one with another.
    var progressRank: Int {
        switch self {
        case .queued: return 0
        case .sent: return 1
        case .applied, .failed, .needsInput: return 2
        }
    }
}

enum ChannelState: String {
    case attached
    case detached
    case none
}

// MARK: - FreezeMessage (iPad to Mac)

struct FreezeMessage: Equatable {
    var captureMs: Int64
    var zoomRect: NormalizedRect
    var t: Double
}

extension FreezeMessage {
    init?(json: [String: Any]) {
        guard let captureMs = canvasInt64(json["captureMs"]),
              let zoomRect = NormalizedRect(json: json["zoomRect"]),
              let t = canvasDouble(json["t"]) else { return nil }
        self.captureMs = captureMs
        self.zoomRect = zoomRect
        self.t = t
    }

    var json: [String: Any] {
        ["captureMs": captureMs, "zoomRect": zoomRect.json, "t": t]
    }
}

// MARK: - FrozenMessage (Mac to iPad)

struct FrozenMessage: Equatable {
    var ok: Bool
}

extension FrozenMessage {
    init?(json: [String: Any]) {
        guard let ok = json["ok"] as? Bool else { return nil }
        self.ok = ok
    }

    var json: [String: Any] {
        ["ok": ok]
    }
}

// MARK: - AnnotationMessage (iPad to Mac)

struct AnnotationMessage: Equatable {
    var sketchPNG: Data
    var zoomRect: NormalizedRect
    var viewport: CanvasViewport
    var note: String?
    var t: Double
}

extension AnnotationMessage {
    /// "sketch" is base64.
    init?(json: [String: Any]) {
        guard let sketchBase64 = json["sketch"] as? String,
              let sketchPNG = Data(base64Encoded: sketchBase64),
              let zoomRect = NormalizedRect(json: json["zoomRect"]),
              let viewport = CanvasViewport(json: json["viewport"]),
              let t = canvasDouble(json["t"]) else { return nil }
        self.sketchPNG = sketchPNG
        self.zoomRect = zoomRect
        self.viewport = viewport
        self.note = json["note"] as? String
        self.t = t
    }

    var json: [String: Any] {
        var dict: [String: Any] = [
            "sketch": sketchPNG.base64EncodedString(),
            "zoomRect": zoomRect.json,
            "viewport": viewport.json,
            "t": t,
        ]
        if let note {
            dict["note"] = note
        }
        return dict
    }
}

// MARK: - AgentReplyMessage (Mac to iPad)

struct AgentReplyMessage: Equatable {
    var annotationId: String
    var status: RoundStatus
    var message: String?
    var prUrl: String?
    var t: Double
}

extension AgentReplyMessage {
    init?(json: [String: Any]) {
        guard let annotationId = json["annotationId"] as? String,
              let statusRaw = json["status"] as? String,
              let status = RoundStatus(rawValue: statusRaw),
              let t = canvasDouble(json["t"]) else { return nil }
        self.annotationId = annotationId
        self.status = status
        self.message = json["message"] as? String
        self.prUrl = json["prUrl"] as? String
        self.t = t
    }

    var json: [String: Any] {
        var dict: [String: Any] = [
            "annotationId": annotationId,
            "status": status.rawValue,
            "t": t,
        ]
        if let message {
            dict["message"] = message
        }
        if let prUrl {
            dict["prUrl"] = prUrl
        }
        return dict
    }
}

// MARK: - CanvasRound (one entry of a rounds snapshot)

struct CanvasRound: Equatable {
    var annotationId: String
    var createdAt: String
    var status: RoundStatus
    var message: String?
    var prUrl: String?
    var note: String?
}

extension CanvasRound {
    init?(json: [String: Any]) {
        guard let annotationId = json["annotationId"] as? String,
              let createdAt = json["createdAt"] as? String,
              let statusRaw = json["status"] as? String,
              let status = RoundStatus(rawValue: statusRaw) else { return nil }
        self.annotationId = annotationId
        self.createdAt = createdAt
        self.status = status
        self.message = json["message"] as? String
        self.prUrl = json["prUrl"] as? String
        self.note = json["note"] as? String
    }

    var json: [String: Any] {
        var dict: [String: Any] = [
            "annotationId": annotationId,
            "createdAt": createdAt,
            "status": status.rawValue,
        ]
        if let message {
            dict["message"] = message
        }
        if let prUrl {
            dict["prUrl"] = prUrl
        }
        if let note {
            dict["note"] = note
        }
        return dict
    }
}

// MARK: - RoundsMessage (Mac to iPad; snapshot of the last N rounds)

struct RoundsMessage: Equatable {
    var rounds: [CanvasRound]   // newest first
}

extension RoundsMessage {
    /// An entry this build cannot read — a status invented later, a field gone
    /// missing — is skipped rather than failing the whole snapshot (M6): the
    /// readable entries are still this device's round history, and skipping
    /// what cannot be understood is the rule PROTOCOL.md section 6 already
    /// applies to unknown types and fields. A missing or non-array `rounds`
    /// key is still not a snapshot at all.
    init?(json: [String: Any]) {
        guard let roundsJSON = json["rounds"] as? [[String: Any]] else { return nil }
        self.rounds = roundsJSON.compactMap(CanvasRound.init(json:))
    }

    var json: [String: Any] {
        ["rounds": rounds.map { $0.json }]
    }

    /// JSON bytes guaranteed < limit, shrinking per ruling 3: full; then
    /// messages and notes cut to `CanvasWire.shrunkTextMaxBytes`; then oldest
    /// rounds (the tail, since `rounds` is newest-first) dropped until it
    /// fits. Never returns nil: worst case is an empty list.
    func encoded(limit: Int = CanvasWire.senderJSONLimit) -> Data {
        func attempt(_ candidate: [CanvasRound]) -> Data? {
            let dict: [String: Any] = ["rounds": candidate.map { $0.json }]
            return try? JSONSerialization.data(withJSONObject: dict)
        }

        if let data = attempt(rounds), data.count < limit {
            return data
        }

        let shrunk = rounds.map { round -> CanvasRound in
            var shrunkRound = round
            if let message = shrunkRound.message {
                shrunkRound.message = message.truncatedUTF8(maxBytes: CanvasWire.shrunkTextMaxBytes)
            }
            if let note = shrunkRound.note {
                shrunkRound.note = note.truncatedUTF8(maxBytes: CanvasWire.shrunkTextMaxBytes)
            }
            return shrunkRound
        }
        if let data = attempt(shrunk), data.count < limit {
            return data
        }

        var remaining = shrunk
        while !remaining.isEmpty {
            remaining.removeLast()
            if let data = attempt(remaining), data.count < limit {
                return data
            }
        }

        return attempt([]) ?? Data(#"{"rounds":[]}"#.utf8)
    }
}

// MARK: - Links a round carries

/// The one place that decides whether a URL a round carries may be opened.
///
/// `prUrl` is filled in by the model, from whatever it read while doing the
/// work, and it reaches the iPad's replies list as a tappable link. The daemon
/// refuses anything but http(s) on the way in and the channel's reply tool
/// refuses it before that (M4); this is the same rule at the point of use, so
/// a round that predates those checks, or came from somewhere else, still
/// cannot open a `javascript:`, `file:` or custom-scheme URL.
enum CanvasLink {
    /// Matches the daemon's limit, so the three checks agree.
    static let maxURLLength = 2048

    static func openableURL(_ text: String?) -> URL? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxURLLength,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

extension CanvasRound {
    /// This round's pull-request link, but only when it is safe to open.
    var openablePRURL: URL? { CanvasLink.openableURL(prUrl) }
}

// MARK: - String truncation

extension String {
    /// Truncates to at most `maxBytes` UTF-8 bytes, cutting on a Character
    /// (grapheme cluster) boundary so a multi-byte character is never split.
    /// Appends nothing (no ellipsis).
    func truncatedUTF8(maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard utf8.count > maxBytes else { return self }

        var result = ""
        var byteCount = 0
        for character in self {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maxBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }
}
