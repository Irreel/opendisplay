// The messages that keep a link up, as opposed to the canvas messages that
// ride on it (spec/wire-protocol.md, section 5).

import Foundation

// MARK: - Hello (both ways)

/// The first message each side sends, in the clear. The Mac speaks first; the
/// iPad answers with its own, and the two then either prove who they are to
/// each other (`verify`) or pair (`pair`…), section 5.7. `version` mismatched
/// on either end ends the link with a `bye` that says so.
struct HelloMessage: Equatable {
    enum Role: String {
        case mac
        case ipad
    }

    var version: Int
    var role: Role
    /// The sender's own name: the Mac's from Sharing settings, the iPad's as
    /// its user set it. Shown by the other side; at most 60 characters.
    var name: String?
    /// iPad only: its install id, which keys everything the Mac remembers
    /// about it (its rounds, a frame it froze, whether it is trusted).
    var installID: String?
    /// iPad only: "iPad" or "iPhone", for copy that names the device.
    var device: String?
    /// The sender's long-term Ed25519 public key (`DeviceIdentity`).
    var key: Data? = nil
    /// The sender's X25519 key for this connection only.
    var ephemeral: Data? = nil
    /// iPad only, when it has this Mac paired: its signature over the verify
    /// transcript, which the Mac checks against the key it pinned.
    var signature: Data? = nil
}

extension HelloMessage {
    init?(json: [String: Any]) {
        guard let version = (json["v"] as? NSNumber)?.intValue,
              let role = (json["role"] as? String).flatMap(Role.init(rawValue:)) else { return nil }
        self.version = version
        self.role = role
        self.name = (json["name"] as? String).flatMap(Self.displayName)
        self.installID = (json["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.device = (json["device"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.key = Self.bytes(json["key"], count: 32)
        self.ephemeral = Self.bytes(json["eph"], count: 32)
        self.signature = Self.bytes(json["sig"], count: 64)
    }

    /// Base64 of exactly `count` bytes, or nil.
    static func bytes(_ value: Any?, count: Int) -> Data? {
        guard let text = value as? String, let data = Data(base64Encoded: text), data.count == count else { return nil }
        return data
    }

    /// The peer's name as something safe to show: control and formatting
    /// characters (newlines, bidirectional overrides) dropped, runs of
    /// whitespace folded to one space, at most 60 characters. Nil when
    /// nothing is left. It is still only what the peer claims to be called.
    static func displayName(_ raw: String) -> String? {
        var kept = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator,
                 .control where scalar.properties.isWhitespace:
                if !lastWasSpace { kept.append(" ") }
                lastWasSpace = true
            case .control, .format:
                continue
            default:
                kept.append(scalar)
                lastWasSpace = false
            }
        }
        let name = String(String(kept).trimmingCharacters(in: .whitespaces).prefix(CanvasWire.macNameMaxCharacters))
        return name.isEmpty ? nil : name
    }

    var json: [String: Any] {
        var dict: [String: Any] = ["v": version, "role": role.rawValue]
        if let name { dict["name"] = String(name.prefix(CanvasWire.macNameMaxCharacters)) }
        if let installID { dict["id"] = installID }
        if let device { dict["device"] = device }
        if let key { dict["key"] = key.base64EncodedString() }
        if let ephemeral { dict["eph"] = ephemeral.base64EncodedString() }
        if let signature { dict["sig"] = signature.base64EncodedString() }
        return dict
    }
}

// MARK: - Status (Mac to iPad)

/// The Mac's side of the Claude Code hop, sent after the hello and again
/// whenever it changes — never on a timer.
struct StatusMessage: Equatable {
    var channel: ChannelState
    /// The folder of the session the next sketch goes to. Absent when there
    /// is none.
    var project: String?

    static let unknown = StatusMessage(channel: .none, project: nil)
}

extension StatusMessage {
    /// An unknown `channel` reads as `.none`, the state that promises nothing.
    init?(json: [String: Any]) {
        guard let raw = json["channel"] as? String else { return nil }
        self.channel = ChannelState(rawValue: raw) ?? .none
        self.project = (json["project"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var json: [String: Any] {
        var dict: [String: Any] = ["channel": channel.rawValue]
        if let project { dict["project"] = project }
        return dict
    }
}

// MARK: - Bye (both ways)

/// Sent just before a side closes on purpose, so the other one does not read
/// the silence as a network fault.
struct ByeMessage: Equatable {
    enum Reason: String {
        /// The iPad locked; it comes back on wake.
        case sleep
        /// The app is quitting, or the user disconnected.
        case quit
        /// The other side speaks a different wire version.
        case version
        /// The iPad adopted a newer connection in this one's place.
        case replaced
        /// The iPad's user kept the Mac it mirrors, or another request was open.
        case inUse
        /// Pairing was declined or cancelled on either side, or it timed out.
        case notPaired
        /// The other side could not prove the identity it was paired with.
        case authFailed
    }

    var reason: Reason
}

extension ByeMessage {
    /// An unknown reason reads as `quit`: deliberate, and nothing more.
    init(json: [String: Any]) {
        reason = (json["reason"] as? String).flatMap(Reason.init(rawValue:)) ?? .quit
    }

    var json: [String: Any] { ["reason": reason.rawValue] }
}
