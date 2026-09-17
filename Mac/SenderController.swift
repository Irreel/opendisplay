// OpenDisplay's connection policy, lifted out of the app file.
//
// Everything here is about deciding which device to dial and over which
// transport — USB auto-connect, WiFi trust-on-first-use, dedupe, the cable
// upgrade and its failover. None of it is specific to OpenDisplay's UI, and a
// second product built on this sender wants all of it, so it now stands on
// its own: no `@main`, no window, no view, no auto-update framework, and —
// because a canvas session forwards no input — no Accessibility injector.
//
// What did depend on those is injected through `SenderControllerConfig`:
// which service to browse, which port to dial, how to build an input sink,
// how to build a canvas delegate, and what to do when the presentation
// changes. OpenDisplay's own values live in `SenderControllerConfig.openDisplay`,
// next to the types they name in `OpenSidecarMacApp.swift`.

import AppKit
import Combine
import Network

/// How the app presents itself. One bundle, switched at runtime via the
/// activation policy — like Raycast/Hammerspoon style background agents.
enum AppPresentation: String, CaseIterable {
    case menuBar, dock, background

    var label: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .dock: return "Dock"
        case .background: return "Background only"
        }
    }
}

enum ConnectionTarget: Hashable {
    case usb(udid: String?)           // wired via built-in usbmuxd; nil = first device
    case wifi(NWBrowser.Result)       // discovered via Bonjour

    /// Stable identity for sessions and persistence — survives Bonjour
    /// re-discovery (fresh NWBrowser.Result) and USB replugs (new DeviceID).
    var sessionID: String {
        switch self {
        case .usb(let udid): return "usb:\(udid ?? "first")"
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint { return "wifi:\(name)" }
            return "wifi:unknown"
        }
    }
}

/// One connected (or connecting) device: its target, its sender pipeline,
/// and the per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let target: ConnectionTarget
    let name: String
    // Assigned by `SenderController.connect` in the same breath as the
    // session is created, and never again. It is not a `let` only because
    // the canvas delegate is built from the session and has to be handed to
    // the sender at construction — so the session must exist first. That
    // leaves one instant where this is nil, and it is exactly the instant
    // `canvasDelegateFactory` runs in: a delegate factory must not read it.
    fileprivate(set) var sender: MacSender!
    // The canvas engine's per-session object, if one was injected. Held
    // strongly here because MacSender holds it weakly: the session is what
    // keeps it alive for exactly as long as the pipeline it belongs to.
    var canvasDelegate: SenderCanvasDelegate?

    @Published var status = "Starting…"
    @Published var framesSent = 0
    @Published var mbps = 0.0
    // The sender's start() threw: the pipeline is freed, only this row's
    // error text remains. A failed session must never swallow a fresh
    // connect for its device the way a live one does.
    @Published var failed = false
    // Receiver's per-install identity (from hello) — the key for recognizing
    // the same physical device across USB and WiFi.
    var deviceID: String?
    // "iPhone" / "iPad" from hello — naming fallback while (or in case)
    // lockdown hasn't resolved the device's real name.
    var deviceKind: String?
    // `target` names the identity the session was created for; the live
    // transport can migrate (cable-in upgrade, unplug failover) — these
    // track where the sender actually is right now.
    @Published var onUSB: Bool
    // The udid the session is (or was last) cabled through, so a usbmuxd
    // detach can be matched back to this session for failover.
    var usbUDID: String?
    // The Bonjour service name this session was started from or failed over
    // to. Kept because browse results routinely arrive without their TXT
    // record (no install id to match on) and the USB device is detached
    // after a failover — the name is then the only link between the session
    // and its service row.
    var wifiServiceName: String?

    // The live TCP path runs over a cable (Thunderbolt Bridge / Ethernet)
    // rather than WiFi — reported by the sender once connected.
    @Published var wired = false

    var transportLabel: String { onUSB ? "USB" : wired ? "Cable" : "WiFi" }

    init(id: String, target: ConnectionTarget, name: String) {
        self.id = id
        self.target = target
        self.name = name
        if case .usb(let udid) = target {
            onUSB = true
            usbUDID = udid
        } else {
            onUSB = false
        }
    }
}

/// Everything `SenderController` used to know about the app around it.
///
/// Defaults reproduce OpenDisplay: its service type and port, no input sink,
/// no canvas engine, and nothing to do when the presentation changes. A
/// controller built with `SenderControllerConfig()` therefore behaves exactly
/// as the one that shipped, minus the window it no longer knows about.
struct SenderControllerConfig {
    /// The service browsed for and the port dialed. Its own type because it
    /// is the part that compiles without AppKit — see `SenderDiscoveryConfig`.
    var discovery = SenderDiscoveryConfig()
    /// How the sender turns a display it just created into an input sink.
    /// Nil forwards no input at all, which is what a canvas session wants.
    var inputSinkFactory: InputSinkFactory? = nil
    /// Called on the main actor when a session is created; the returned delegate is retained by the DeviceSession.
    var canvasDelegateFactory: (@MainActor (DeviceSession) -> SenderCanvasDelegate?)? = nil
    /// Called on the main actor whenever `presentation` changes (OpenDisplay shows its main window here).
    var onPresentationChanged: (@MainActor (AppPresentation) -> Void)? = nil
}

@MainActor
final class SenderController: ObservableObject {
    private let config: SenderControllerConfig

    @Published var presentation = AppPresentation(
        rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar {
        didSet {
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
            config.onPresentationChanged?(presentation)
        }
    }

    @Published var sessions: [DeviceSession] = []
    @Published var discovered: [NWBrowser.Result] = []
    @Published var usbDevices: [UsbmuxDevice] = []
    // `-host x.x.x.x` / `-port n` bypass usbmuxd with a manual TCP endpoint
    // (debugging escape hatch, e.g. an iproxy or SSH tunnel).
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1"
    @Published var port: String
    // `-mode mirror` / `-mode extend` launch argument also works.
    @Published var mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .extend
    @Published var quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }

    var running: Bool { !sessions.isEmpty }

    private var browser: NWBrowser?
    private var usbWatcher: UsbmuxDeviceWatcher?

    // Connection policy — one session per physical device, and the cable
    // wins whenever it's available (lower, steadier latency than WiFi):
    //
    //  - USB devices connect on attach ("plug in and go") unless the user
    //    explicitly disconnected them once (usbDisabled).
    //  - Plugging the cable in while the device streams over WiFi migrates
    //    the live session onto USB; unplugging it fails over to WiFi when
    //    the device's service is visible — otherwise the session ends after
    //    the usual grace. Migrations swap only the socket (switchTransport):
    //    the virtual display survives, so no screen flash, no window
    //    reshuffle — the earlier no-switching policy existed because
    //    migration used to mean destroying and recreating the session.
    //  - WiFi devices the user connected before (wifiRemembered) reconnect
    //    in a short window at LAUNCH only — never mid-session.
    // `-autostart NO` disables all auto-connecting, including migrations.
    private var usbDisabled = Set(UserDefaults.standard.stringArray(forKey: "usbDisabled") ?? []) {
        didSet { UserDefaults.standard.set(Array(usbDisabled), forKey: "usbDisabled") }
    }
    private var wifiRemembered = Set(UserDefaults.standard.stringArray(forKey: "wifiRemembered") ?? []) {
        didSet { UserDefaults.standard.set(Array(wifiRemembered), forKey: "wifiRemembered") }
    }
    // Install id learned from each USB device's hello, persisted, so the
    // same hardware is recognized across transports even when the user
    // renamed the advertised service. @Published so the device list regroups
    // the moment an identity is learned.
    @Published private var installIDByUDID: [String: String] =
        UserDefaults.standard.dictionary(forKey: "installIDByUDID") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(installIDByUDID, forKey: "installIDByUDID") }
    }
    private let autoConnectEnabled = UserDefaults.standard.object(forKey: "autostart") == nil
        || UserDefaults.standard.bool(forKey: "autostart")

    // Bonjour usually reports devices before usbmuxd does — WiFi reconnects
    // wait out this window so a cabled device is dialed over USB first. The
    // deadline closes the window for good: a remembered WiFi device that
    // appears later was brought near the Mac mid-session, which is a user
    // action to confirm, not auto-grab.
    private var wifiAutoConnectArmed = false
    private let wifiAutoConnectDeadline = Date().addingTimeInterval(12)

    init(config: SenderControllerConfig) {
        self.config = config
        port = UserDefaults.standard.string(forKey: "port")
            ?? String(config.discovery.devicePort)
        startBrowsing()
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            guard let self else { return }
            let detached = Set(self.usbDevices.map(\.udid)).subtracting(devices.map(\.udid))
            self.usbDevices = devices
            self.failover(detachedUDIDs: detached)
            self.autoConnect()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.wifiAutoConnectArmed = true
            self.autoConnect()
        }
    }

    private func startBrowsing() {
        // TXT records carry the receiver's install id (new receivers).
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: config.discovery.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.discovered = Array(results)
                self.endSessionsWhoseServiceVanished()
                self.autoConnect()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    // MARK: - Physical-device identity

    private func serviceName(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func txtID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"] }
        return nil
    }

    /// Same hardware? Strong match: the service's install id equals the id
    /// this USB device announced in a (past or present) hello. Fallback for
    /// old receivers: lockdown device name equals the service name.
    private func sameDevice(_ result: NWBrowser.Result, _ device: UsbmuxDevice) -> Bool {
        if let id = txtID(of: result), installIDByUDID[device.udid] == id { return true }
        if let name = serviceName(of: result), let usbName = device.name,
           usbName == name { return true }
        return false
    }

    /// The session (over either transport) already serving this USB device.
    /// A failed session serves nothing — it must not block auto-connecting
    /// the same physical device over the other transport.
    private func activeSession(coveringUSB device: UsbmuxDevice) -> DeviceSession? {
        if let direct = session(for: "usb:\(device.udid)"), !direct.failed { return direct }
        return sessions.first { s in
            guard !s.failed, case .wifi(let result) = s.target else { return false }
            if let id = installIDByUDID[device.udid],
               s.deviceID == id || txtID(of: result) == id { return true }
            return serviceName(of: result) != nil && device.name == serviceName(of: result)
        }
    }

    /// The session (over either transport) already serving this WiFi service.
    /// Failed sessions are excluded for the same reason as above.
    private func activeSession(coveringWiFi result: NWBrowser.Result) -> DeviceSession? {
        if let name = serviceName(of: result), let direct = session(for: "wifi:\(name)"),
           !direct.failed {
            return direct
        }
        return sessions.first { s in
            guard !s.failed, case .usb(let udid) = s.target else { return false }
            if let id = txtID(of: result), s.deviceID == id { return true }
            if let udid, let device = usbDevices.first(where: { $0.udid == udid }),
               sameDevice(result, device) { return true }
            // Browse results routinely lack their TXT record and the USB
            // device is gone after a failover — the service name is then
            // the only remaining link to the session.
            let name = serviceName(of: result)
            return name != nil && (name == s.wifiServiceName || name == s.name)
        }
    }

    // MARK: - Connection policy

    private func autoConnect() {
        guard autoConnectEnabled else { return }
        dedupeSessions()
        // The -host/-port escape hatch is an explicit choice — dial it like
        // the wired devices (it joins them, not replaces them).
        if UserDefaults.standard.object(forKey: "host") != nil,
           !usbDisabled.contains("usb:first"), session(for: "usb:first") == nil {
            connect(to: .usb(udid: nil))
        }
        for device in usbDevices {
            if let covering = activeSession(coveringUSB: device) {
                // usbDisabled gates auto-connecting a device, not the
                // transport of a session the user deliberately has running —
                // however it was started, the cable is better: take it.
                upgradeToUSB(covering, device: device)
            } else if !usbDisabled.contains("usb:\(device.udid)") {
                connect(to: .usb(udid: device.udid))
            }
        }
        guard wifiAutoConnectArmed, Date() < wifiAutoConnectDeadline else { return }
        for result in discovered {
            let target = ConnectionTarget.wifi(result)
            if wifiRemembered.contains(target.sessionID),
               activeSession(coveringWiFi: result) == nil,
               !cabled(result) {
                connect(to: target)
            }
        }
    }

    /// An attached, auto-connectable USB device is (about to be) dialed over
    /// the cable — its WiFi service must not be grabbed in the launch race.
    private func cabled(_ result: NWBrowser.Result) -> Bool {
        usbDevices.contains {
            sameDevice(result, $0) && !usbDisabled.contains("usb:\($0.udid)")
        }
    }

    /// Cable plugged in while the device streams over WiFi: migrate the live
    /// session onto USB. No-op when the session is already cabled.
    private func upgradeToUSB(_ session: DeviceSession, device: UsbmuxDevice) {
        guard !session.onUSB, let portNum = UInt16(port) else { return }
        Log.info("cable attached for \(session.id) — migrating to USB")
        session.onUSB = true
        session.usbUDID = device.udid
        // The match may have been by name only — pin the strong identity so
        // future matching (and the next launch) recognizes the pair.
        if let id = session.deviceID { installIDByUDID[device.udid] = id }
        session.sender.switchTransport(to: .usb(udid: device.udid, port: portNum))
    }

    /// Cable unplugged under a live session: fail over to the device's WiFi
    /// service if one is visible. Without one the session keeps its normal
    /// fate — retry over USB through the grace period, then end.
    private func failover(detachedUDIDs: Set<String>) {
        guard autoConnectEnabled, !detachedUDIDs.isEmpty else { return }
        for session in sessions where session.onUSB {
            guard let udid = session.usbUDID, detachedUDIDs.contains(udid),
                  let result = wifiService(for: session) else { continue }
            Log.info("cable detached for \(session.id) — failing over to WiFi")
            session.onUSB = false
            session.wifiServiceName = serviceName(of: result)
            session.sender.switchTransport(to: .tcp(result.endpoint))
        }
    }

    /// A quit receiver app loses its Bonjour advertisement within ~1s, far
    /// faster than WiFi dial timeouts can notice (dials to a withdrawn
    /// service stall rather than getting refused). Report the withdrawal to
    /// each live WiFi session's sender; it only acts if its connection is
    /// already down too, which together proves the app is gone. Debounced
    /// 3s: an mDNS record can drop briefly during a WiFi roam — only a
    /// withdrawal that persists counts. One-shot, guarded re-check, so
    /// overlapping browse events at worst repeat an idempotent call.
    private func endSessionsWhoseServiceVanished() {
        for session in sessions where !session.onUSB {
            guard wifiService(for: session) == nil else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
                guard let self, let session,
                      self.sessions.contains(where: { $0 === session }),
                      self.wifiService(for: session) == nil else { return }
                session.sender.peerServiceWithdrawn()
            }
        }
    }

    /// The discovered WiFi service belonging to this session's device.
    private func wifiService(for session: DeviceSession) -> NWBrowser.Result? {
        discovered.first { result in
            if let id = txtID(of: result), let deviceID = session.deviceID {
                return id == deviceID
            }
            let name = serviceName(of: result)
            return name != nil && (name == session.wifiServiceName || name == session.name)
        }
    }

    /// Safety net, not a feature: if identity was learned too late (old
    /// receiver, renamed service) and one physical device ended up with two
    /// sessions, the transports steal the receiver's single connection from
    /// each other forever. Keep the cable, drop the WiFi twin.
    private func dedupeSessions() {
        // Failed sessions hold no pipeline: a USB corpse must never win the
        // "keep the cable" rule against a working WiFi session.
        let usbSessionIDs = Set(sessions.compactMap { s -> String? in
            if case .usb = s.target, !s.failed { return s.deviceID }
            return nil
        })
        let cabledNames = Set(usbDevices.compactMap { device -> String? in
            guard let s = session(for: "usb:\(device.udid)"), !s.failed else { return nil }
            return device.name
        })
        for s in sessions {
            guard case .wifi(let result) = s.target else { continue }
            let duplicate = (s.deviceID.map { usbSessionIDs.contains($0) } ?? false)
                || (txtID(of: result).map { usbSessionIDs.contains($0) } ?? false)
                || (serviceName(of: result).map { cabledNames.contains($0) } ?? false)
            if duplicate {
                Log.info("two sessions for one device — keeping the cable, dropping \(s.id)")
                end(s)
            }
        }
    }

    /// Human-readable device name for a target (no transport suffix — the
    /// UI shows transports separately).
    func label(for target: ConnectionTarget) -> String {
        switch target {
        case .usb(let udid):
            if let device = usbDevices.first(where: { $0.udid == udid }), let name = device.name {
                return name
            }
            return udid == nil ? "Manual (\(host):\(port))" : "iPhone / iPad"
        case .wifi(let result):
            return serviceName(of: result) ?? "WiFi device"
        }
    }

    func session(for id: String) -> DeviceSession? {
        sessions.first { $0.id == id }
    }

    /// Derive a stable, per-device display serial from the session identity.
    /// FNV-1a over the id string; macOS keys saved display arrangement on
    /// vendor/product/serial, so each device keeps its screen position.
    private static func displaySerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    // A display identity macOS saved hostile state for (see
    // MacSender.setupExtend) is abandoned permanently: the validated offset
    // from the device's base identity is persisted per session id and every
    // future session starts from it.
    private static func identityOffsetKey(for id: String) -> String { "displaySerialBump.\(id)" }
    private func identityOffset(for id: String) -> UInt32 {
        UInt32(clamping: UserDefaults.standard.integer(forKey: Self.identityOffsetKey(for: id)))
    }

    func connect(to target: ConnectionTarget, userInitiated: Bool = false,
                 awaitingWake: Bool = false) {
        let id = target.sessionID
        if let existing = session(for: id) {
            // A failed session holds no pipeline — replace the corpse
            // instead of letting it swallow the fresh attempt.
            guard existing.failed else { return }
            end(existing)
        }

        // Never create a second session for the same physical device — the
        // receiver holds one connection, so a twin would steal it. But an
        // explicit user click overrides: e.g. right after unplugging the
        // cable, the dying USB session sits in its 10s reconnect grace and
        // would otherwise swallow the tap on the WiFi row.
        let covering: DeviceSession?
        switch target {
        case .usb(let udid?):
            covering = usbDevices.first(where: { $0.udid == udid })
                .flatMap { activeSession(coveringUSB: $0) }
        case .wifi(let result):
            covering = activeSession(coveringWiFi: result)
        default:
            covering = nil
        }
        if let covering {
            guard userInitiated else { return }
            Log.info("user chose \(id) — taking over from \(covering.id)")
            end(covering)
        }

        // Connecting a device clears its "don't auto-connect" state.
        switch target {
        case .usb: usbDisabled.remove(id)
        case .wifi: wifiRemembered.insert(id)
        }

        let transport: SenderTransport
        switch target {
        case .usb(let udid):
            guard let portNum = UInt16(port) else { return }
            if UserDefaults.standard.object(forKey: "host") != nil, udid == nil {
                // Manual override: dial a plain TCP endpoint instead of usbmuxd.
                transport = .tcp(.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: portNum)!))
            } else {
                transport = .usb(udid: udid, port: portNum)
            }
        case .wifi(let result):
            transport = .tcp(result.endpoint)
        }

        let name = label(for: target)
        // The session is built first because the canvas delegate is built
        // from it, and MacSender decides at construction whether this is a
        // canvas session — so the delegate has to exist before the sender.
        let session = DeviceSession(id: id, target: target, name: name)
        session.canvasDelegate = config.canvasDelegateFactory?(session)
        let sender = MacSender(transport: transport, name: name, mode: mode,
                               quality: quality, displaySerial: Self.displaySerial(for: id),
                               identityOffset: identityOffset(for: id),
                               awaitingWake: awaitingWake,
                               inputSinkFactory: config.inputSinkFactory,
                               canvasDelegate: session.canvasDelegate)
        session.sender = sender
        if case .wifi(let result) = target {
            session.wifiServiceName = serviceName(of: result)
        }
        sender.onStatus = { [weak session] text in
            // Retry loops re-announce the same status every second (e.g. the
            // asleep wait) — only a change is worth the UI churn and the log line.
            guard let session, session.status != text else { return }
            session.status = text
            Log.info("status[\(id)]: \(text)")
        }
        sender.onHello = { [weak self, weak session] info in
            guard let self, let session else { return }
            session.deviceID = info.id
            session.deviceKind = info.device
            if case .usb(let udid?) = session.target, let installID = info.id {
                self.installIDByUDID[udid] = installID
            }
            self.dedupeSessions()
            // The learned identity may reveal that this WiFi session's device
            // is cabled — take the upgrade opportunity right away.
            self.autoConnect()
        }
        sender.onStats = { [weak session] frames, mbps in
            session?.framesSent = frames
            session?.mbps = mbps
        }
        sender.onDisconnected = { [weak self, weak session] in
            // Device unplugged / left the network and stayed gone: end this
            // session fully (virtual display + capture + indicator). No
            // transport fallback — reconnecting is the user's call.
            guard let self, let session else { return }
            Log.info("device disconnected — session \(session.id) stopped")
            self.end(session)
        }
        sender.onPeerSleeping = { [weak self, weak session] in
            // The device locked. Unlike a plain disconnect this is a
            // known-temporary state announced by the receiver, so ending
            // the session (which frees the cursor from the now-invisible
            // display) is paired with a replacement session that dials
            // patiently until the device wakes and accepts again.
            guard let self, let session else { return }
            let target = session.target
            Log.info("session \(session.id) asleep — display down, waiting for wake")
            self.end(session)
            self.connect(to: target, awaitingWake: true)
        }
        sender.onCaptureStoppedByUser = { [weak self, weak session] in
            // The user stopped the capture in the system UI — same intent as
            // the in-app Disconnect, so it also opts the device out of
            // auto-connect (or the next browse event would resurrect it).
            guard let self, let session else { return }
            Log.info("session \(session.id) capture stopped via the system UI — honoring as disconnect")
            self.disconnect(session)
        }
        sender.onDisplayIdentityBumped = { [weak session] totalOffset in
            // The sender reports the validated absolute offset — store it
            // as-is. Adding would double-count when a rotation rebuild
            // re-discovers the same poisoned identity within one session.
            guard let session else { return }
            UserDefaults.standard.set(Int(totalOffset), forKey: Self.identityOffsetKey(for: session.id))
            Log.info("display identity for \(session.id) moved to offset \(totalOffset) — "
                + "macOS saved hostile state for the old one")
        }
        sender.onTransportPath = { [weak session] wired in
            session?.wired = wired
        }
        sender.onPeerClosed = { [weak self, weak session] in
            // The receiver app quit — a deliberate goodbye, so no reconnect
            // waits around. Reopening the app is a fresh start handled by
            // the normal discovery/auto-connect paths.
            guard let self, let session else { return }
            Log.info("session \(session.id) closed by the receiver — ending")
            self.end(session)
        }
        sessions.append(session)
        Task {
            do {
                try await sender.start()
            } catch is CancellationError {
                // stopped by the user while waiting — nothing to report
            } catch {
                Log.info("sender failed to start: \(error)")
                session.status = "Failed: \(error.localizedDescription)"
                // Free the half-built pipeline: a leaked virtual display
                // would keep holding this device's serial, and a parked
                // live-looking session would swallow every future connect.
                session.failed = true
                sender.stop()
            }
        }
    }

    /// User-initiated disconnect: also opt the device out of auto-connect.
    func disconnect(_ session: DeviceSession) {
        switch session.target {
        case .usb: usbDisabled.insert(session.id)
        case .wifi: wifiRemembered.remove(session.id)
        }
        // A migrated session is also reachable the other way — opt that side
        // out too, or auto-connect resurrects the device moments later.
        if session.onUSB, let udid = session.usbUDID { usbDisabled.insert("usb:\(udid)") }
        if let name = session.wifiServiceName { wifiRemembered.remove("wifi:\(name)") }
        end(session)
    }

    func disconnectAll() {
        sessions.forEach { disconnect($0) }
    }

    /// Restart a session that failed to start (its pipeline is already
    /// freed): tear the corpse out and dial the same target fresh. The
    /// socket-only Reconnect can't help there — nothing was ever built.
    func retry(_ session: DeviceSession) {
        let target = session.target
        end(session)
        connect(to: target, userInitiated: true)
    }

    private func end(_ session: DeviceSession) {
        session.sender.stop()
        sessions.removeAll { $0.id == session.id }
    }

    /// Mode/quality apply per-pipeline at construction — rebuild every session.
    func restartAll() {
        guard running else { return }
        let targets = sessions.map(\.target)
        sessions.forEach { $0.sender.stop() }
        sessions.removeAll()
        targets.forEach { connect(to: $0) }
        autoConnect()   // a rebuilt WiFi session may deserve its cable back
    }

    // MARK: - Device list (one row per physical device)

    struct DeviceEntry: Identifiable {
        let id: String
        let name: String
        let usbTarget: ConnectionTarget?
        let wifiTarget: ConnectionTarget?

        var transportLabel: String {
            switch (usbTarget != nil, wifiTarget != nil) {
            case (true, true): return "USB · WiFi"
            case (true, false): return "USB"
            case (false, true): return "WiFi"
            default: return ""
            }
        }
        /// Lowest latency first.
        var preferredTarget: ConnectionTarget? { usbTarget ?? wifiTarget }
    }

    var deviceEntries: [DeviceEntry] {
        var entries: [DeviceEntry] = []
        var mergedServices = Set<String>()
        var coveredSessionIDs = Set<String>()

        for device in usbDevices {
            // A discovered WiFi service for the same hardware folds into
            // this row instead of appearing as a second device.
            let twin = discovered.first { sameDevice($0, device) }
            if let twin, let name = serviceName(of: twin) { mergedServices.insert(name) }
            let usbTarget = ConnectionTarget.usb(udid: device.udid)
            coveredSessionIDs.insert(usbTarget.sessionID)
            if let twin { coveredSessionIDs.insert(ConnectionTarget.wifi(twin).sessionID) }
            // A WiFi-identity session migrated onto this cable serves the
            // device even when its service is no longer advertised.
            if let covering = activeSession(coveringUSB: device) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(
                id: "device:\(device.udid)",
                name: device.name
                    ?? twin.flatMap(serviceName)
                    ?? session(for: usbTarget.sessionID)?.deviceKind
                    ?? "iPhone / iPad",
                usbTarget: usbTarget,
                wifiTarget: twin.map { .wifi($0) }))
        }
        if UserDefaults.standard.object(forKey: "host") != nil {
            let target = ConnectionTarget.usb(udid: nil)
            coveredSessionIDs.insert(target.sessionID)
            entries.append(DeviceEntry(id: target.sessionID, name: label(for: target),
                                       usbTarget: target, wifiTarget: nil))
        }
        for result in discovered {
            guard let name = serviceName(of: result), !mergedServices.contains(name)
            else { continue }
            let target = ConnectionTarget.wifi(result)
            coveredSessionIDs.insert(target.sessionID)
            // A USB-identity session that failed over to WiFi serves this
            // service — claim it, or it would dangle as a second row and
            // this one would offer a Connect that steals the receiver.
            if let covering = activeSession(coveringWiFi: result) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(id: "service:\(name)", name: name,
                                       usbTarget: nil, wifiTarget: target))
        }
        // Sessions whose device vanished from discovery (e.g. Bonjour record
        // gone while the stream is still alive) keep a row to disconnect.
        for session in sessions where !coveredSessionIDs.contains(session.id) {
            entries.append(DeviceEntry(id: session.id, name: session.name,
                                       usbTarget: nil, wifiTarget: nil))
        }
        return entries
    }

    func session(for entry: DeviceEntry) -> DeviceSession? {
        if let target = entry.usbTarget {
            if let s = session(for: target.sessionID) { return s }
            if case .usb(let udid?) = target,
               let device = usbDevices.first(where: { $0.udid == udid }),
               let s = activeSession(coveringUSB: device) { return s }
        }
        if let target = entry.wifiTarget {
            if let s = session(for: target.sessionID) { return s }
            // Transport-migrated sessions keep their original identity — a
            // USB-identity session failed over to WiFi still owns this row.
            if case .wifi(let result) = target,
               let s = activeSession(coveringWiFi: result) { return s }
        }
        return session(for: entry.id)   // dangling-session rows
    }
}
