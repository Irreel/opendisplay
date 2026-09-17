// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral.

import Foundation

/// The wire-protocol contract between the two apps, decoupled from the app's
/// marketing version. See COMPATIBILITY.md.
///
/// Bumped only when the wire changes, not every release, so UI-only releases
/// never trigger a compatibility event. A peer that advertises no version is
/// protocol 1 — that's every install in the field that predates the handshake.
enum WireProtocol {
    /// The protocol version this build speaks.
    static let version = 3

    /// Protocol version that introduced Apple Pencil / proximity wire messages.
    /// Peers below this get pencil input as legacy `touch` events.
    static let pencilWireVersion = 3

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let updateRequired = "updateRequired"    // Mac -> phone: peer is below the Mac's floor
    static let sleeping = "sleeping"                // phone -> Mac: device locked, reconnect on wake
    static let closing = "closing"                  // phone -> Mac: app quit, end the session for good

    // Design Canvas (see PROTOCOL.md section 10: additive types need no `pv`
    // bump, and a peer that predates them ignores them). Only exchanged on a
    // session whose `welcome` carried `canvas: true`; a plain OpenDisplay
    // session never sends or accepts one. Design Canvas code uses its own
    // `CanvasWire` constants — these are the same strings, kept here so this
    // file still describes the whole wire and so MacSender's switch can name
    // them.
    static let freeze = "freeze"                    // phone -> Mac: hold the frame I am sketching on
    static let frozen = "frozen"                    // Mac -> phone: the frozen still, or why not
    static let annotation = "annotation"            // phone -> Mac: a finished sketch + its note
    static let agentReply = "agentReply"            // Mac -> phone: a round's status or the agent's reply
    static let rounds = "rounds"                    // Mac -> phone: recent rounds snapshot
}
