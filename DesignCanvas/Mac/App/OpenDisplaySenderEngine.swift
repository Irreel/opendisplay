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
    var onDevicesChanged: (() -> Void)?

    /// The two `ping` fields every session relays to its iPad. The app writes them; the sessions
    /// read them from the sender's queue.
    private let status = CanvasStatus()
    private let hub: CanvasHub
    private var controller: SenderController?
    private var sessionListObserver: AnyCancellable?
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
        // No input sink, ever: a canvas session forwards no touch, scroll, pencil or proximity,
        // and this app never asks for Accessibility (spec section 1).
        config.inputSinkFactory = nil
        config.canvasDelegateFactory = { [hub] session in
            hub.makeSession(deviceName: session.name)
        }
        let controller = SenderController(config: config)
        self.controller = controller

        // `$sessions` covers devices arriving and leaving; each session's own `objectWillChange`
        // covers its status and transport changing while it stays in the list. Both are received
        // on the main run loop so the rebuild reads the value *after* it lands —
        // `objectWillChange` fires before it.
        sessionListObserver = controller.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in self?.observeEach(sessions) }
    }

    func stop() {
        sessionListObserver = nil
        sessionObservers = []
        controller?.sessions.forEach { $0.sender?.stop() }
        controller = nil
        hub.stop()
        publish([])
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
        publish(controller.sessions.map {
            EngineDevice(id: $0.id, name: $0.name, status: $0.status, onUSB: $0.onUSB)
        })
    }

    /// Only a real change is republished — sessions publish often (frame counters, throughput),
    /// and none of that is in `EngineDevice`.
    private func publish(_ latest: [EngineDevice]) {
        guard latest != devices else { return }
        devices = latest
        onDevicesChanged?()
    }
}
