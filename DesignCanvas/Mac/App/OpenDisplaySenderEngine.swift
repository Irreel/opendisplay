// The real `SenderEngine`: OpenDisplay's sender, joined to the canvas daemon.
//
// App-only on purpose. It names `SenderController`, `DeviceSession` and, through them, the whole
// capture/encode/socket stack, none of which compiles into the hostless `DesignCanvasTests`
// bundle — which is exactly why the shell talks to the `SenderEngine` protocol instead and the
// tests use `FakeSenderEngine`. Everything here is wiring; the logic it wires together
// (`CanvasHub`, `CanvasSession`, `CanvasStatus`) is tested on its own.

import Combine
import Foundation

@MainActor
final class OpenDisplaySenderEngine: SenderEngine {
    private(set) var devices: [EngineDevice] = []
    private(set) var discovered: [DiscoveredDevice] = []
    var onDevicesChanged: (() -> Void)?

    var pendingUploads: Int { hub.pendingUploads }

    /// The two `ping` fields every session relays to its iPad. The app writes them; the sessions
    /// read them from the sender's queue.
    private let status = CanvasStatus()
    private let hub: CanvasHub
    private var controller: SenderController?
    private var sessionListObserver: AnyCancellable?
    private var controllerObserver: AnyCancellable?
    private var sessionObservers: [AnyCancellable] = []

    init(daemon: DaemonAPI = DaemonClient()) {
        hub = CanvasHub(daemon: daemon, status: status)
    }

    func start() {
        guard controller == nil else { return }
        hub.start()

        var config = SenderControllerConfig()
        // Design Canvas advertises its own service and dials its own port, so an OpenDisplay
        // sender and a Design Canvas iPad never dial each other — including over USB, where
        // there is no service type to tell them apart (plan ruling 1).
        config.discovery = SenderDiscoveryConfig(bonjourType: "_designcanvas._tcp", devicePort: 9100)
        // Its own virtual-display identity too: the same cabled iPad hashes to the same display
        // serial in both products, and macOS keys saved display state — including the state that
        // keeps an identity from ever coming online — on vendor/product/serial.
        config.displayIdentity = .designCanvas
        // No input sink, ever: a canvas session forwards no touch, scroll, pencil or proximity,
        // and this app never asks for Accessibility (spec section 1).
        config.inputSinkFactory = nil
        config.canvasDelegateFactory = { [hub] session in
            hub.makeSession(deviceName: session.name)
        }
        let controller = SenderController(config: config)
        self.controller = controller

        // `$sessions` covers devices arriving and leaving; each session's own `objectWillChange`
        // covers its status and transport changing while it stays in the list; the controller's
        // own `objectWillChange` covers what it discovers (Bonjour results and usbmuxd devices),
        // which is the list the menu offers a Connect for. All are received on the main run loop
        // so the rebuild reads the value *after* it lands — `objectWillChange` fires before it.
        sessionListObserver = controller.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in self?.observeEach(sessions) }
        controllerObserver = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
    }

    func stop() {
        sessionListObserver = nil
        controllerObserver = nil
        sessionObservers = []
        controller?.sessions.forEach { $0.sender?.stop() }
        controller = nil
        hub.stop()
        publish([], [])
    }

    // MARK: - Connecting

    /// `userInitiated` is the point: it overrides the "one session per physical device" guard (so
    /// a tap right after unplugging is not swallowed by the dying USB session's grace) and, for a
    /// WiFi target, adds the device to the controller's remembered set, which is what makes it
    /// auto-reconnect on later launches.
    func connect(id: String) {
        guard let controller,
              let entry = controller.deviceEntries.first(where: { $0.id == id }),
              let target = entry.preferredTarget else { return }
        controller.connect(to: target, userInitiated: true)
    }

    func disconnect(id: String) {
        guard let controller, let session = controller.session(for: id) else { return }
        controller.disconnect(session)
    }

    func setProjectName(_ name: String?) {
        status.projectName = name
    }

    func setChannelState(_ state: ChannelState) {
        status.channelState = state
    }

    // MARK: - Device list

    private func observeEach(_ sessions: [DeviceSession]) {
        sessionObservers = sessions.map { session in
            session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.rebuild() }
        }
        rebuild()
    }

    private func rebuild() {
        guard let controller else { return }
        // One row per physical device, as the controller groups them; the ones it is already
        // serving are the `devices` list, and the rest are what a Connect is offered for. A row
        // with no target at all is a session whose device vanished from discovery — it is covered
        // by `devices`, never offered a Connect.
        let waiting = controller.deviceEntries.compactMap { entry -> DiscoveredDevice? in
            guard controller.session(for: entry) == nil, entry.preferredTarget != nil else { return nil }
            return DiscoveredDevice(id: entry.id, name: entry.name, transport: entry.transportLabel)
        }
        publish(
            controller.sessions.map {
                EngineDevice(id: $0.id, name: $0.name, status: $0.status, onUSB: $0.onUSB)
            },
            waiting
        )
    }

    /// Only a real change is republished — sessions publish often (frame counters, throughput),
    /// and none of that is in `EngineDevice`.
    private func publish(_ latest: [EngineDevice], _ latestDiscovered: [DiscoveredDevice]) {
        guard latest != devices || latestDiscovered != discovered else { return }
        devices = latest
        discovered = latestDiscovered
        onDevicesChanged?()
    }
}
