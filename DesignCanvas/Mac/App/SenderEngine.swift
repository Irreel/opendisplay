// The seam between the menu-bar shell and the sender.
//
// The real engine (`OpenDisplaySenderEngine`) drives a ScreenCaptureKit stream of the Mac's
// screen, an encoder and a socket, none of which a unit test can stand up — and none of which
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

/// One device the sender can see but is not serving: a Bonjour service on the LAN, or a cabled
/// device the user has disconnected. `id` is the controller's own device-row id, which is what
/// `SenderEngine.connect(id:)` takes back.
///
/// This exists because `SenderController` auto-connects USB devices and *remembered* WiFi ones
/// only, and a WiFi device is remembered only once the user has connected to it from a UI. With
/// no such UI, a WiFi iPad could never be started at all (I1, PRD D1).
struct DiscoveredDevice: Equatable, Identifiable {
    let id: String
    let name: String
    /// "USB", "WiFi" or "USB · WiFi" — which transports this row could be dialed over.
    let transport: String
}

@MainActor
protocol SenderEngine: AnyObject {
    /// The devices the sender is serving right now.
    var devices: [EngineDevice] { get }
    /// Devices the sender can see but is not serving — the ones the menu offers a Connect for.
    var discovered: [DiscoveredDevice] { get }
    /// Called whenever either list changes, so the menu can republish without polling.
    var onDevicesChanged: (() -> Void)? { get set }
    /// Sketches accepted from the iPads and not yet uploaded to the daemon. Read on the app's
    /// health poll; the menu says so when it is not zero, because a daemon that is down otherwise
    /// leaves the user with no sign that their rounds are still queued (I3).
    var pendingUploads: Int { get }

    func start()
    func stop()

    /// Dial one `discovered` device, as a deliberate user action: that is also what makes the
    /// sender remember a WiFi device, so it auto-reconnects on later launches.
    func connect(id: String)
    /// Stop serving one `devices` entry (its `id`), and stop auto-connecting it.
    func disconnect(id: String)

    /// The selected project's folder name, or nil when there is none. Relayed to every iPad in
    /// the `ping` status fields; an absent name is how "no project" is expressed on the wire.
    func setProjectName(_ name: String?)
    /// The menu's verdict on the Claude Code hop, as of the last health poll (`ChannelState`).
    func setChannelState(_ state: ChannelState)
}
