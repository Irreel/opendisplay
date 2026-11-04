// The seam between the menu-bar shell and the sender.
//
// The real engine (`MirrorEngine`) drives a ScreenCaptureKit stream of the Mac's screen,
// encoders and sockets, none of which a unit test can stand up. So the shell only ever talks to
// this protocol, and the tests hand it a fake (spec section 1: "behind a `SenderEngine`
// protocol so it is fakeable in tests").

import Foundation

/// One device the engine is serving (or trying to), flattened to what the menu draws.
struct EngineDevice: Equatable, Identifiable {
    enum State: Equatable {
        /// Dialing, or connected and waiting for the iPad's hello.
        case connecting
        /// The iPad is asking its user whether to switch to this Mac over
        /// WiFi, away from the Mac it is cabled to.
        case awaitingApproval
        /// The iPad said hello and is showing the screen.
        case mirroring
        /// The iPad is reachable but nothing answers: the app is not open.
        case waitingForApp
        /// The iPad locked; it resumes on wake.
        case asleep
        /// Not attached and not advertised right now.
        case unreachable
        /// Another Mac took this iPad over.
        case inUseElsewhere
        /// The iPad's app speaks a different wire version.
        case needsUpdate
    }

    let id: String
    let name: String
    let state: State
    let onUSB: Bool

    var connected: Bool { state == .mirroring }
}

/// One device the engine can see but is not serving: a Bonjour service on the LAN, or a cabled
/// device the user has disconnected. `id` is the engine's id for it, which is what
/// `SenderEngine.connect(id:)` takes back.
///
/// The engine connects USB devices and iPads the user connected before on its own; anything else
/// waits here for a click (I1, PRD D1).
struct DiscoveredDevice: Equatable, Identifiable {
    let id: String
    let name: String
    /// "USB", "WiFi" or "USB · WiFi" — which transports this row could be dialed over.
    let transport: String
}

@MainActor
protocol SenderEngine: AnyObject {
    /// The devices the engine is serving, or trying to.
    var devices: [EngineDevice] { get }
    /// Devices the engine can see but is not serving — the ones the menu offers a Connect for.
    var discovered: [DiscoveredDevice] { get }
    /// Called whenever either list changes, so the menu can republish without polling.
    var onDevicesChanged: (() -> Void)? { get set }
    /// Sketches accepted from the iPads and not yet uploaded to the daemon. Read on the app's
    /// health poll; the menu says so when it is not zero, because a daemon that is down otherwise
    /// leaves the user with no sign that their rounds are still queued (I3).
    var pendingUploads: Int { get }
    /// Frames reached the engine within the last two seconds. Outranks the Screen Recording
    /// preflight in the menu: a running capture is proof of the permission, whatever
    /// `CGPreflightScreenCaptureAccess` says (it said no on macOS 26 while mirroring ran).
    var isCapturing: Bool { get }

    func start()
    func stop()

    /// Dial one `discovered` device, as a deliberate user action: that is also what makes the
    /// engine trust it, so it reconnects on its own from then on, over WiFi too.
    func connect(id: String)
    /// Stop serving one `devices` entry (its `id`), and stop auto-connecting it.
    func disconnect(id: String)

    /// The menu's verdict on the Claude Code hop, as of the last health poll (`ChannelState`).
    func setChannelState(_ state: ChannelState)
}
