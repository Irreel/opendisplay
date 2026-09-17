// Everything StreamReceiver has to remember about a Design Canvas session,
// as a pure value. The socket half of the receiver is untestable without a
// live link, so the decisions live here instead: whether the Mac on the other
// end is a canvas sender, what its channel and project are, whether the
// picture is frozen, and whether input may leave this device at all.
//
// A plain OpenDisplay session never turns any of this on: the gate is a
// `welcome` carrying `canvas: true`, which only a Design Canvas Mac sends.
// With it absent, `route` answers `.none` for every type and the receiver
// behaves exactly as it did before this type existed.
//
// Foundation only, no OpenDisplay types: this file is compiled into the
// macOS 12 receiver target and into the hostless DesignCanvasTests bundle,
// which does not compile `Shared/Protocol.swift`. The message-type strings
// are therefore literals here; they are the same strings `WireMessage`
// names (PROTOCOL.md, "Wire additions to OpenDisplay").

import Foundation

struct CanvasReceiverState: Equatable {

    /// The connected Mac said `welcome.canvas: true`. Until it does, no
    /// canvas message is delivered and no canvas feature is reachable.
    private(set) var macSupportsCanvas = false

    /// `"attached"`, `"detached"` or `"none"` — the Mac's channel state,
    /// piggybacked on its liveness ping. Nil until a ping carries one.
    private(set) var channel: String?

    /// The project the Mac has selected, nil when it has none.
    private(set) var project: String?

    /// The picture is held: frames are dropped at the door so the last one
    /// stays on screen while the user sketches on it.
    private(set) var frozen = false

    /// Set by the app: a canvas receiver forwards no touch, scroll, pencil
    /// or proximity, whatever the Mac would do with it (plan constraint
    /// "No input forwarding on a canvas session").
    var suppressesInput = false

    /// What an inbound control type this receiver does not handle itself
    /// should become.
    enum Routed: Equatable {
        case none
        case canvasMessage(type: String)
    }

    /// The canvas types the Mac sends us. `freeze` and `annotation` go the
    /// other way, so they are never routed inbound.
    private static let inboundCanvasTypes: Set<String> = ["frozen", "agentReply", "rounds"]

    /// A new connection was adopted: the previous Mac's capability and state
    /// say nothing about this one. Input suppression is app configuration
    /// rather than session state, so it survives.
    mutating func connectionReset() {
        macSupportsCanvas = false
        channel = nil
        project = nil
        frozen = false
    }

    /// The Mac identified itself. Canvas is enabled only for a JSON `true`:
    /// a missing key, `false`, or the string `"true"` all leave it off, so a
    /// plain OpenDisplay Mac can never accidentally open the canvas path.
    mutating func handleWelcome(_ object: [String: Any]) {
        macSupportsCanvas = (object["canvas"] as? Bool) == true
    }

    /// The Mac's liveness ping, which a canvas sender merges its channel and
    /// project into. The two are deliberately asymmetric: the sender always
    /// states its channel, so an absent one means "this ping is not from a
    /// canvas sender" and the last known value stands; but it omits
    /// `project` when nothing is selected, so an absent one clears it.
    mutating func handlePing(_ object: [String: Any]) {
        if let channel = object["channel"] as? String { self.channel = channel }
        project = object["project"] as? String
    }

    /// Where an inbound control type this receiver has no case for should go.
    /// Canvas types are delivered only on a canvas session; everything else
    /// is ignored, exactly as an unknown type always was (PROTOCOL.md 6).
    mutating func route(type: String) -> Routed {
        guard macSupportsCanvas, Self.inboundCanvasTypes.contains(type) else { return .none }
        return .canvasMessage(type: type)
    }

    /// Hold or release the picture. Returns true when the caller must ask the
    /// Mac for a keyframe: thawing resumes mid-GOP, so the decoder needs a
    /// fresh sync point before anything it is handed will render. Freezing
    /// and repeats of the current value need nothing.
    mutating func setFrozen(_ value: Bool) -> Bool {
        guard value != frozen else { return false }
        frozen = value
        return !value
    }

    /// Frames parsed now must not reach the display layer.
    var shouldDropFrames: Bool { frozen }

    /// Input messages may be put on the wire.
    var allowsInputSend: Bool { !suppressesInput }
}
