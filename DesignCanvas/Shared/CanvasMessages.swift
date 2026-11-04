import Foundation

/// The Design Canvas wire, version 1 (spec/wire-protocol.md): its address,
/// its limits, and every message `type` both apps exchange.
enum CanvasWire {
    /// Bumped when the wire changes. Both apps ship together, so there is no
    /// negotiation: a peer that says another version is told so and dropped.
    static let version = 1
    /// The iPad listens here. Over USB the Mac dials this port through
    /// usbmuxd; over WiFi it finds the iPad by `serviceType`.
    static let port: UInt16 = 9100
    static let serviceType = "_designcanvas._tcp"
    /// Bonjour TXT keys the iPad advertises: its install id and wire version.
    static let txtIDKey = "id"
    static let txtVersionKey = "v"

    /// The largest frame either side accepts (length field, kind included).
    static let maxFrameLength = 32 << 20          // 32 MiB
    /// The largest JSON part of a message; the rest of a frame is attachment.
    static let maxJSONLength = 1 << 20            // 1 MiB
    /// The largest sketch PNG an `annotation` may carry. Refused on the iPad,
    /// where the designer still has the strokes and can erase some (M10).
    static let sketchMaxBytes = 24 << 20          // 24 MiB

    /// Both sides ping this often, and give up on a link that has sent no
    /// byte at all for `silenceTimeout`.
    static let pingInterval: TimeInterval = 2
    static let silenceTimeout: TimeInterval = 6
    /// How long the iPad leaves "switch to this Mac over WiFi?" up before it
    /// answers for the user: keep the cable. The asking Mac waits a little
    /// longer, so the iPad's answer is the one that lands.
    static let switchRequestTimeout: TimeInterval = 30
    static let switchRequestMacWait: TimeInterval = 45
    /// After a request ends without a Switch (the user kept the cable, it
    /// timed out, or the asking Mac left), further WiFi requests are turned
    /// away unasked for this long, so a LAN neighbour cannot wear the user
    /// down with prompts.
    static let switchRequestCooldown: TimeInterval = 60

    // Link
    static let hello = "hello"
    static let ping = "ping"
    static let pong = "pong"
    static let keyframe = "keyframe"
    static let bye = "bye"
    static let status = "status"
    /// iPad to Mac: your hello is waiting on the iPad's user (section 5.6).
    static let asking = "asking"

    // Canvas
    static let freeze = "freeze"
    static let frozen = "frozen"
    static let annotation = "annotation"
    static let agentReply = "agentReply"
    static let rounds = "rounds"
    /// The connected Claude Code sessions and the target (Mac to iPad), and the
    /// iPad's choice of target back (`spec/technical_doc-ClaudeMods.md` section 5).
    static let sessions = "sessions"
    static let selectSession = "selectSession"

    static let macNameMaxCharacters = 60
    static let annotationBaseKey = "base"
    /// The target session the iPad was showing when Done was tapped (X23).
    static let annotationSessionKey = "session"
    static let sessionsMaxEntries = 20
    static let sessionTextMaxCharacters = 80
    static let sessionFolderMaxCharacters = 60

    static let replyMessageMaxBytes = 2048
    static let roundsSnapshotLimit = 20
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

/// A frame number: a non-negative whole number. JSON carries it as a double,
/// which is exact far beyond any count a capture reaches.
private func canvasFrameNumber(_ any: Any?) -> UInt64? {
    guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    guard value >= 0, value < 9e15, value.rounded() == value else { return nil }
    return UInt64(value)
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

// MARK: - CanvasSurface

/// What the iPad is showing, and so what a sketch was drawn on: the live
/// mirror of the Mac, or a blank page the iPad renders itself
/// (`spec/PRD-BlankCanvas.md`). Chosen on the iPad; the Mac only ever learns
/// it from an `annotation`'s `base`.
enum CanvasSurface: String {
    case mirror
    case blank
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

/// The Mac's verdict on its Claude Code hop, relayed to the iPad in `status.channel` (P1). It is
/// the menu's verdict (D7), not the daemon's raw subscriber count: `attached` is a connected
/// session, `existing` is a session the app did not start (the menu's "Another session"),
/// `detached` a daemon with no session, `none` no usable daemon. A receiver reads an unknown
/// string as `none`.
enum ChannelState: String {
    case attached
    case detached
    case existing
    case none
}

// MARK: - FreezeMessage (iPad to Mac)

/// Enter Draw Mode on the frame that is on screen: `frame` is the number the
/// video packet carried, which is what the Mac keeps the clean original under.
struct FreezeMessage: Equatable {
    var frame: UInt64
    var t: Double
}

extension FreezeMessage {
    init?(json: [String: Any]) {
        guard let frame = canvasFrameNumber(json["frame"]),
              let t = canvasDouble(json["t"]) else { return nil }
        self.frame = frame
        self.t = t
    }

    var json: [String: Any] {
        ["frame": frame, "t": t]
    }
}

// MARK: - FrozenMessage (Mac to iPad)

/// The answer to a `freeze`: whether the Mac still holds that frame.
struct FrozenMessage: Equatable {
    var frame: UInt64
    var ok: Bool
}

extension FrozenMessage {
    init?(json: [String: Any]) {
        guard let ok = json["ok"] as? Bool, let frame = canvasFrameNumber(json["frame"]) else { return nil }
        self.frame = frame
        self.ok = ok
    }

    var json: [String: Any] {
        ["frame": frame, "ok": ok]
    }
}

// MARK: - AnnotationMessage (iPad to Mac)

/// A finished sketch. The PNG is the message's attachment, not a JSON field:
/// the strokes only, transparent, covering `viewport`.
struct AnnotationMessage: Equatable {
    var sketchPNG: Data
    var viewport: CanvasViewport
    var note: String?
    var t: Double
    /// `.blank` when the sketch was drawn on the blank page: no `freeze` came
    /// first and the Mac composites it on white. On the wire only when blank.
    var base: CanvasSurface = .mirror
    /// The session this sketch was drawn for: the target the iPad was showing
    /// at Done. Absent when there was no target to show; the Mac then uses the
    /// target of the moment.
    var session: String?
}

extension AnnotationMessage {
    /// An absent or unknown `base` is a mirror sketch. An empty attachment is
    /// no sketch at all.
    init?(json: [String: Any], attachment: Data) {
        guard !attachment.isEmpty,
              let viewport = CanvasViewport(json: json["viewport"]),
              let t = canvasDouble(json["t"]) else { return nil }
        self.sketchPNG = attachment
        self.viewport = viewport
        self.note = json["note"] as? String
        self.t = t
        self.base = (json[CanvasWire.annotationBaseKey] as? String).flatMap(CanvasSurface.init(rawValue:)) ?? .mirror
        self.session = (json[CanvasWire.annotationSessionKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The JSON half; `sketchPNG` goes as the attachment.
    var json: [String: Any] {
        var dict: [String: Any] = [
            "viewport": viewport.json,
            "t": t,
        ]
        if let note {
            dict["note"] = note
        }
        if base == .blank {
            dict[CanvasWire.annotationBaseKey] = base.rawValue
        }
        if let session {
            dict[CanvasWire.annotationSessionKey] = session
        }
        return dict
    }
}

// MARK: - Sessions (Mac to iPad) and SelectSession (iPad to Mac)

/// What a Claude Code session is doing, as far as the iPad needs to know.
/// `waiting`: a permission dialog is open at the Mac (X8). An unknown value
/// reads as `busy`, the state that promises nothing.
enum CanvasSessionState: String {
    case idle
    case busy
    case waiting
}

/// One connected Claude Code session, as both apps list it (X25). `id` is the
/// mod's instance id, which is what `selectSession` and `annotation.session`
/// carry back.
struct CanvasSessionEntry: Equatable, Identifiable {
    var id: String
    var folder: String
    var title: String?
    var branch: String?
    /// ISO 8601, as the daemon reports it. Shown when there is no title.
    var startedAt: String
    var lastReplyAt: String?
    var state: CanvasSessionState
}

extension CanvasSessionEntry {
    /// From the wire (`id`) or from the daemon's snapshot (`instance`).
    init?(json: [String: Any]) {
        guard let id = (json["id"] as? String) ?? (json["instance"] as? String), !id.isEmpty,
              let folder = json["folder"] as? String,
              let startedAt = json["startedAt"] as? String else { return nil }
        self.id = id
        self.folder = folder
        self.title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.branch = (json["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.startedAt = startedAt
        self.lastReplyAt = json["lastReplyAt"] as? String
        self.state = (json["state"] as? String).flatMap(CanvasSessionState.init(rawValue:)) ?? .busy
    }

    var json: [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "folder": String(folder.prefix(CanvasWire.sessionFolderMaxCharacters)),
            "startedAt": startedAt,
            "state": state.rawValue,
        ]
        if let title { dict["title"] = String(title.prefix(CanvasWire.sessionTextMaxCharacters)) }
        if let branch { dict["branch"] = String(branch.prefix(CanvasWire.sessionTextMaxCharacters)) }
        if let lastReplyAt { dict["lastReplyAt"] = lastReplyAt }
        return dict
    }
}

/// The connected sessions and which one receives sketches. `target` nil with
/// several sessions means the user has to pick before sending (X26).
struct SessionsMessage: Equatable {
    var sessions: [CanvasSessionEntry]
    var target: String?

    static let empty = SessionsMessage(sessions: [], target: nil)

    var targetEntry: CanvasSessionEntry? {
        guard let target else { return nil }
        return sessions.first { $0.id == target }
    }

    /// Several sessions and none chosen: Done must wait for a pick.
    var needsPick: Bool { sessions.count > 1 && targetEntry == nil }
}

extension SessionsMessage {
    /// Unreadable entries are skipped, like unreadable rounds; a missing or
    /// non-array `sessions` is not a sessions message at all. A `target` that
    /// names no listed session reads as no target.
    init?(json: [String: Any]) {
        guard let entries = json["sessions"] as? [[String: Any]] else { return nil }
        self.sessions = entries.compactMap(CanvasSessionEntry.init(json:))
        let named = json["target"] as? String
        self.target = sessions.contains { $0.id == named } ? named : nil
    }

    /// At most `sessionsMaxEntries` entries, with the text fields already cut by
    /// `CanvasSessionEntry.json`. The target is kept even when the list is cut.
    var json: [String: Any] {
        var listed = Array(sessions.prefix(CanvasWire.sessionsMaxEntries))
        if let entry = targetEntry, !listed.contains(where: { $0.id == entry.id }) {
            listed[listed.count - 1] = entry
        }
        var dict: [String: Any] = ["sessions": listed.map { $0.json }]
        if let target = targetEntry?.id { dict["target"] = target }
        return dict
    }
}

struct SelectSessionMessage: Equatable {
    var id: String
    var t: Double
}

extension SelectSessionMessage {
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty, let t = canvasDouble(json["t"]) else { return nil }
        self.id = id
        self.t = t
    }

    var json: [String: Any] { ["id": id, "t": t] }
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
    /// what cannot be understood is the rule the wire applies to unknown
    /// types and fields. A missing or non-array `rounds` key is still not a
    /// snapshot at all.
    init?(json: [String: Any]) {
        guard let roundsJSON = json["rounds"] as? [[String: Any]] else { return nil }
        self.rounds = roundsJSON.compactMap(CanvasRound.init(json:))
    }

    var json: [String: Any] {
        ["rounds": rounds.map { $0.json }]
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
