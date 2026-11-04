// The messages that keep a link up, as opposed to the canvas messages that
// ride on it (spec/wire-protocol.md, section 5).

import Foundation

// MARK: - Hello (both ways)

/// The first message each side sends. The Mac speaks first; the iPad answers
/// once it has adopted the connection. `version` mismatched on either end
/// ends the link with a `bye` that says so.
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
}

extension HelloMessage {
    init?(json: [String: Any]) {
        guard let version = (json["v"] as? NSNumber)?.intValue,
              let role = (json["role"] as? String).flatMap(Role.init(rawValue:)) else { return nil }
        self.version = version
        self.role = role
        self.name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(CanvasWire.macNameMaxCharacters)) }
        self.installID = (json["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.device = (json["device"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var json: [String: Any] {
        var dict: [String: Any] = ["v": version, "role": role.rawValue]
        if let name { dict["name"] = String(name.prefix(CanvasWire.macNameMaxCharacters)) }
        if let installID { dict["id"] = installID }
        if let device { dict["device"] = device }
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
        /// A newer connection from the same Mac replaced this one.
        case replaced
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
