// The seam between the menu-bar shell and the sender.
//
// The real engine (`OpenDisplaySenderEngine`) drives a virtual display, a ScreenCaptureKit
// stream, an encoder and a socket, none of which a unit test can stand up — and none of which
// compile into a hostless test bundle. So the shell only ever talks to this protocol, and the
// tests hand it a fake (spec section 1: "behind a `SenderEngine` protocol so it is fakeable in
// tests").

import Foundation

/// One connected (or connecting) device, flattened to what the menu draws: `SenderController`'s
/// `DeviceSession` is an `ObservableObject` full of pipeline state, and none of it belongs in a
/// value the menu diffs.
struct EngineDevice: Equatable, Identifiable {
    let id: String
    let name: String
    let status: String
    let onUSB: Bool
}

@MainActor
protocol SenderEngine: AnyObject {
    /// The devices the sender is serving right now.
    var devices: [EngineDevice] { get }
    /// Called whenever `devices` changes, so the menu can republish without polling.
    var onDevicesChanged: (() -> Void)? { get set }
    /// Sketches accepted from the iPads and not yet uploaded to the daemon. Read on the app's
    /// health poll; the menu says so when it is not zero, because a daemon that is down otherwise
    /// leaves the user with no sign that their rounds are still queued (I3).
    var pendingUploads: Int { get }

    func start()
    func stop()

    /// The selected project's folder name, or nil when there is none. Relayed to every iPad in
    /// the `ping` status fields; an absent name is how "no project" is expressed on the wire.
    func setProjectName(_ name: String?)
    /// Whether a Claude Code channel is attached, as of the last health poll.
    func setChannelState(_ state: ChannelState)
}
