// The real `SenderEngine`: the Mac's screen, mirrored to every iPad it serves,
// joined to the canvas daemon.
//
// Two halves on two threads. `MirrorEngine` lives on the main actor and makes
// the decisions the menu sees: which iPads exist, which to connect, what each
// row says. `StreamRouter` lives on the stream queue and moves the bytes: it
// runs the one screen capture while any iPad is streaming, fans each frame out
// to the links, and joins each link to its iPad's canvas session.

import Foundation
import SystemConfiguration

@MainActor
final class MirrorEngine: SenderEngine {
    private(set) var devices: [EngineDevice] = []
    private(set) var discovered: [DiscoveredDevice] = []
    var onDevicesChanged: (() -> Void)?

    var pendingUploads: Int { hub.pendingUploads }
    var isCapturing: Bool { status.isCapturing(now: Date()) }

    private let status = CanvasStatus()
    private let frames = CleanFrameStore()
    private let hub: CanvasHub
    private let router: StreamRouter
    private let watcher = DeviceWatcher()
    private let macName: String?
    private var started = false

    /// One per iPad the engine means to serve.
    private struct Served {
        let link: MirrorLink
        /// How the engine recognises this iPad among what it can see. The
        /// install id arrives with the first hello; until then the udid or
        /// service name it was dialed by stands in.
        var installID: String?
        var udid: String?
        var serviceName: String?
        var phase: LinkPhase = .idle
        var peerName: String?
        /// The user clicked Connect on this iPad while it could only be
        /// reached over WiFi: its hello over WiFi makes it trusted there.
        var clickedOverWiFi = false
        /// When the iPad was last seen in the directory, for dropping links to
        /// iPads that have gone for good.
        var lastSeen = Date()

        func matches(_ device: VisibleDevice) -> Bool {
            if let installID, let other = device.installID { return installID == other }
            if let udid, device.usb?.udid == udid { return true }
            if let serviceName, device.service?.name == serviceName { return true }
            return false
        }
    }

    private var served: [Served] = []
    private var visible: [VisibleDevice] = []

    // Persisted connection policy and identity.
    private var policy: ConnectPolicy {
        didSet { if policy != oldValue { savePolicy() } }
    }
    private var installIDByUDID: [String: String] {
        didSet { UserDefaults.standard.set(installIDByUDID, forKey: Self.installIDsKey) }
    }

    /// An iPad gone from both USB and WiFi for this long, with no connection,
    /// is dropped from the menu; it reappears (and reconnects) when it is back.
    private static let goneAfter: TimeInterval = 15

    init(daemon: DaemonAPI = DaemonClient()) {
        hub = CanvasHub(daemon: daemon, status: status, frames: frames)
        router = StreamRouter(status: status, frames: frames, sessions: hub.store)
        let trimmed = (SCDynamicStoreCopyComputerName(nil, nil) as String?)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        macName = trimmed.flatMap { $0.isEmpty ? nil : String($0.prefix(CanvasWire.macNameMaxCharacters)) }
        let defaults = UserDefaults.standard
        policy = ConnectPolicy(
            trusted: Set(defaults.stringArray(forKey: Self.trustedKey) ?? []),
            disconnectedIDs: Set(defaults.stringArray(forKey: Self.disconnectedIDsKey) ?? []),
            disconnectedUDIDs: Set(defaults.stringArray(forKey: Self.disconnectedUDIDsKey) ?? []))
        installIDByUDID = defaults.dictionary(forKey: Self.installIDsKey) as? [String: String] ?? [:]
    }

    func start() {
        guard !started else { return }
        started = true
        hub.start()
        router.onPhaseChange = { [weak self] linkID, phase, peer in
            Task { @MainActor in self?.linkChanged(linkID, phase: phase, peer: peer) }
        }
        router.onCaptureStoppedByUser = { [weak self] in
            Task { @MainActor in self?.captureStoppedByUser() }
        }
        watcher.onChange = { [weak self] in self?.directoryChanged() }
        watcher.start()
        // Gone iPads are pruned on a clock, not only on directory events.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.started else { return }
                self.directoryChanged()
            }
        }
    }

    func stop() {
        started = false
        watcher.stop()
        for entry in served { entry.link.stop(bye: .quit) }
        served = []
        hub.stop()
        publish()
    }

    // MARK: - Connecting

    func connect(id: String) {
        guard let device = visible.first(where: { $0.id == id }) else { return }
        policy.connected(device)
        let overWiFi = device.usb == nil && device.service != nil
        if let index = served.firstIndex(where: { $0.matches(device) }) {
            served[index].clickedOverWiFi = served[index].clickedOverWiFi || overWiFi
            served[index].link.reconnect()
        } else {
            serve(device, clickedOverWiFi: overWiFi)
        }
        publish()
    }

    func disconnect(id: String) {
        guard let index = served.firstIndex(where: { $0.link.id == id }) else { return }
        let entry = served.remove(at: index)
        policy.disconnected(installID: entry.installID, udid: entry.udid)
        entry.link.stop(bye: .quit)
        router.remove(entry.link)
        publish()
    }

    func setChannelState(_ state: ChannelState) {
        hub.setChannelState(state)
    }

    // MARK: - What the Mac can see

    private func directoryChanged() {
        guard started else { return }
        visible = DeviceDirectory.merge(usb: watcher.usb, services: watcher.services,
                                        installIDByUDID: installIDByUDID)
        let now = Date()
        var kept: [Served] = []
        for var entry in served {
            if let device = visible.first(where: { entry.matches($0) }) {
                if entry.udid == nil { entry.udid = device.usb?.udid }
                if let name = device.service?.name { entry.serviceName = name }
                let paths = permittedPaths(entry, device)
                entry.link.update(paths: paths)
                // An iPad seen only over a WiFi path it is not trusted on
                // counts as gone: its link is dropped, and the iPad is offered
                // for a Connect click instead.
                if paths.best != nil { entry.lastSeen = now }
                if case .streaming = entry.phase {
                    kept.append(entry)
                } else if now.timeIntervalSince(entry.lastSeen) < Self.goneAfter {
                    kept.append(entry)
                } else {
                    Log.info("engine: \(entry.peerName ?? device.name) has no path it may be dialed on — dropping its link")
                    entry.link.stop()
                    router.remove(entry.link)
                }
            } else {
                entry.link.update(paths: .none)
                if case .streaming = entry.phase {
                    kept.append(entry)
                } else if now.timeIntervalSince(entry.lastSeen) < Self.goneAfter {
                    kept.append(entry)
                } else {
                    Log.info("engine: \(entry.peerName ?? "an iPad") is gone — dropping its link")
                    entry.link.stop()
                    router.remove(entry.link)
                }
            }
        }
        served = kept
        for device in visible where !served.contains(where: { $0.matches(device) })
            && policy.shouldAutoConnect(device) {
            serve(device)
        }
        publish()
    }

    private func serve(_ device: VisibleDevice, clickedOverWiFi: Bool = false) {
        let link = router.makeLink(macName: macName)
        let entry = Served(link: link, installID: device.installID, udid: device.usb?.udid,
                           serviceName: device.service?.name, clickedOverWiFi: clickedOverWiFi)
        served.append(entry)
        Log.info("engine: connecting \(device.name) (\(device.transportLabel))")
        link.start(paths: permittedPaths(entry, device))
    }

    /// The cable always; WiFi only for an iPad the user trusted there, so a
    /// cabled session never fails over onto a service that merely claims the
    /// iPad's name or id (anything on the LAN can advertise either). Over
    /// WiFi the hello must then name the id the trust is for; only a service
    /// the user clicked that advertised no id is taken at its word.
    private func permittedPaths(_ entry: Served, _ device: VisibleDevice) -> LinkPaths {
        let wifiTrusted = entry.clickedOverWiFi || device.installID.map { policy.trusted.contains($0) } == true
        var paths = device.paths
        if wifiTrusted {
            paths.wifiInstallID = device.installID ?? entry.installID
        } else {
            paths.wifi = nil
            paths.wifiInstallID = nil
        }
        return paths
    }

    private func linkChanged(_ linkID: String, phase: LinkPhase, peer: HelloMessage?) {
        guard let index = served.firstIndex(where: { $0.link.id == linkID }) else { return }
        served[index].phase = phase
        if let peer {
            served[index].peerName = peer.name
            if let installID = peer.installID, served[index].installID != installID {
                served[index].installID = installID
                // Only a hello over the cable may name the cable's iPad: one
                // over WiFi could come from anything on the LAN.
                if case .streaming(.usb) = phase, let udid = served[index].udid {
                    installIDByUDID[udid] = installID
                }
            }
            if case .streaming(.wifi) = phase, served[index].clickedOverWiFi, let installID = peer.installID {
                policy.connectedOverWiFi(installID: installID)
            }
        }
        // A learned install id can fold a cable and a service into one iPad.
        directoryChanged()
    }

    /// The user stopped sharing from the system's recording indicator: honour
    /// it like Disconnect on every iPad, or the next directory event would
    /// start capturing again.
    private func captureStoppedByUser() {
        Log.info("engine: screen sharing stopped from the system UI — disconnecting every iPad")
        for entry in served { disconnect(id: entry.link.id) }
    }

    // MARK: - Publishing

    private func publish() {
        let latest = served.map { entry -> EngineDevice in
            let device = visible.first(where: { entry.matches($0) })
            return EngineDevice(id: entry.link.id,
                                name: entry.peerName ?? device?.name ?? "iPad",
                                state: Self.state(for: entry.phase),
                                onUSB: Self.onUSB(entry.phase, device: device))
        }
        let waiting = visible.filter { device in !served.contains { $0.matches(device) } }
            .map { DiscoveredDevice(id: $0.id, name: $0.name, transport: $0.transportLabel) }
        guard latest != devices || waiting != discovered else { return }
        devices = latest
        discovered = waiting
        onDevicesChanged?()
    }

    private static func state(for phase: LinkPhase) -> EngineDevice.State {
        switch phase {
        case .idle, .stopped: return .unreachable
        case .dialing, .handshaking: return .connecting
        case .streaming: return .mirroring
        case .retrying(.appNotOpen): return .waitingForApp
        case .retrying(.asleep): return .asleep
        case .retrying(.network): return .connecting
        case .yielded: return .inUseElsewhere
        case .versionMismatch: return .needsUpdate
        }
    }

    private static func onUSB(_ phase: LinkPhase, device: VisibleDevice?) -> Bool {
        switch phase {
        case .dialing(let transport), .handshaking(let transport), .streaming(let transport):
            return transport == .usb
        default:
            return device?.usb != nil
        }
    }

    // MARK: - Persistence

    private static let trustedKey = "trustedDevices"
    private static let disconnectedIDsKey = "disconnectedDevices"
    private static let disconnectedUDIDsKey = "disconnectedUSB"
    private static let installIDsKey = "installIDByUDID"

    private func savePolicy() {
        let defaults = UserDefaults.standard
        defaults.set(Array(policy.trusted).sorted(), forKey: Self.trustedKey)
        defaults.set(Array(policy.disconnectedIDs).sorted(), forKey: Self.disconnectedIDsKey)
        defaults.set(Array(policy.disconnectedUDIDs).sorted(), forKey: Self.disconnectedUDIDsKey)
    }
}

/// The stream-queue half: links, the capture and the canvas sessions, joined.
final class StreamRouter: MirrorLinkDelegate {
    /// Main-actor listeners, called on the stream queue.
    var onPhaseChange: ((_ linkID: String, _ phase: LinkPhase, _ peer: HelloMessage?) -> Void)?
    var onCaptureStoppedByUser: (() -> Void)?

    let queue = DispatchQueue(label: "designcanvas.stream", qos: .userInteractive)
    private let capture: ScreenCapture
    private let frames: CleanFrameStore
    private let sessions: CanvasSessionStore

    // Stream queue only.
    private var streaming: [ObjectIdentifier: MirrorLink] = [:]
    private var attached: [ObjectIdentifier: CanvasSession] = [:]

    init(status: CanvasStatus, frames: CleanFrameStore, sessions: CanvasSessionStore) {
        self.frames = frames
        self.sessions = sessions
        capture = ScreenCapture(queue: queue, status: status)
        capture.onFrame = { [weak self] frame in
            guard let self else { return }
            for link in self.streaming.values { link.offer(frame) }
        }
        capture.onStoppedByUser = { [weak self] in self?.onCaptureStoppedByUser?() }
    }

    func makeLink(macName: String?) -> MirrorLink {
        let link = MirrorLink(queue: queue, macName: macName, frames: frames)
        link.delegate = self
        return link
    }

    /// The engine is done with this link.
    func remove(_ link: MirrorLink) {
        queue.async { self.linkDidDrop(link) }
    }

    // MARK: - MirrorLinkDelegate (stream queue)

    func link(_ link: MirrorLink, didChangePhase phase: LinkPhase) {
        onPhaseChange?(link.id, phase, link.peer)
    }

    func link(_ link: MirrorLink, didHello peer: HelloMessage) {
        let key = ObjectIdentifier(link)
        streaming[key] = link
        capture.setWanted(true)
        // An iPad without an install id has no round history to join; it still
        // mirrors, and its sketches have nowhere to go.
        guard let installID = peer.installID else {
            Log.info("router: an iPad said hello without an install id — mirroring only")
            return
        }
        let session = sessions.session(installID: installID, deviceName: peer.name ?? "iPad")
        attached[key] = session
        session.attach(link)
    }

    func link(_ link: MirrorLink, didReceive message: WireMessage) {
        attached[ObjectIdentifier(link)]?.receive(type: message.type, object: message.object,
                                                  attachment: message.attachment)
    }

    func linkDidDrop(_ link: MirrorLink) {
        let key = ObjectIdentifier(link)
        streaming[key] = nil
        attached.removeValue(forKey: key)?.detach(link)
        if streaming.isEmpty { capture.setWanted(false) }
    }

    func latestFrame(for link: MirrorLink) -> CapturedFrame? {
        capture.latest
    }
}
