// The one object that knows both halves: OpenDisplay's `StreamReceiver` and
// Design Canvas's `CanvasModel`. Everything in DesignCanvas/iOS/Logic is
// written against `CanvasReceiving` so it can be unit-tested without a socket;
// this is the conformance, plus the subscriptions that push the receiver's
// news into the model.

import Combine
import Foundation

final class ReceiverAdapter: CanvasReceiving {

    let receiver: StreamReceiver
    private var cancellables = Set<AnyCancellable>()

    init(receiver: StreamReceiver) {
        self.receiver = receiver
    }

    // MARK: - CanvasReceiving

    var isConnected: Bool { receiver.connected }

    var supportsCanvas: Bool { receiver.canvas.macSupportsCanvas }

    func currentCaptureMs() -> Int64? { receiver.currentCaptureMs() }

    func setFrozen(_ frozen: Bool) { receiver.setFrozen(frozen) }

    func sendCanvas(_ message: [String: Any], completion: @escaping (Bool) -> Void) {
        receiver.sendCanvas(message, completion: completion)
    }

    // MARK: - Wiring

    /// Point the receiver at `model`. Called once, before `start()`.
    ///
    /// Main-actor isolated on purpose: the closures below are formed here, so
    /// they inherit that isolation and may call the model — which is
    /// `@MainActor` — directly. `StreamReceiver` delivers every one of these on
    /// the main queue, so the isolation the compiler infers is the truth.
    @MainActor
    func attach(_ model: CanvasModel) {
        // M3 and the plan's "no input forwarding on a canvas session": this
        // app never sends a touch, scroll, pencil or proximity message, and
        // the switch is thrown before the listener exists so there is no
        // window in which one could leave.
        receiver.suppressesInput = true

        receiver.onWelcome = { [weak model] canvas in
            model?.welcomeReceived(canvas: canvas)
        }
        receiver.onCanvasMessage = { [weak model] type, object in
            model?.canvasMessage(type: type, object: object)
        }

        // `@Published` fires on willSet, so the property still holds the old
        // value when a subscriber runs. Both of these feed answers the model
        // reads straight back off the receiver (`isConnected`,
        // `supportsCanvas`), so hop to the next main-queue turn, by which time
        // the assignment has landed.
        receiver.$connected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak model] connected in
                model?.connectionChanged(connected: connected)
            }
            .store(in: &cancellables)

        // The Mac's channel and project ride its liveness ping into
        // `CanvasReceiverState` (P1). The state is published only when it
        // actually changes, so this is not a per-ping wake-up.
        receiver.$canvas
            .receive(on: DispatchQueue.main)
            .sink { [weak model] canvas in
                model?.pingReceived(channel: canvas.channel, project: canvas.project)
            }
            .store(in: &cancellables)
    }
}
