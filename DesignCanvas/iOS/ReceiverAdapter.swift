// The one object that knows both halves: the socket's `CanvasReceiver` and
// the Draw Mode's `CanvasModel`. Everything in iOS/Logic is written against
// `CanvasReceiving` so it can be unit-tested without a socket; this is the
// conformance, plus the subscriptions that push the receiver's news into the
// model.

import Combine
import Foundation

final class ReceiverAdapter: CanvasReceiving {

    let receiver: CanvasReceiver
    private var cancellables = Set<AnyCancellable>()

    init(receiver: CanvasReceiver) {
        self.receiver = receiver
    }

    // MARK: - CanvasReceiving

    var isConnected: Bool { receiver.connected }

    func currentFrame() -> UInt64? { receiver.currentFrame() }

    func setFrozen(_ frozen: Bool) { receiver.setFrozen(frozen) }

    func send(_ type: String, _ object: [String: Any], attachment: Data,
              completion: @escaping (Bool) -> Void) {
        receiver.send(type, object, attachment: attachment, completion: completion)
    }

    // MARK: - Wiring

    /// Point the receiver at `model`. Called once, before `start()`.
    ///
    /// Main-actor isolated on purpose: the closures below are formed here, so
    /// they inherit that isolation and may call the model — which is
    /// `@MainActor` — directly. The receiver delivers every one of these on
    /// the main queue, so the isolation the compiler infers is the truth.
    @MainActor
    func attach(_ model: CanvasModel) {
        receiver.onMacHello = { [weak model] hello in
            model?.macHelloReceived(name: hello.name)
        }
        receiver.onMessage = { [weak model] message in
            model?.canvasMessage(type: message.type, object: message.object)
        }
        // `@Published` fires on willSet, so the property still holds the old
        // value when a subscriber runs, and the model reads `isConnected`
        // straight back off the receiver: hop to the next main-queue turn, by
        // which time the assignment has landed.
        receiver.$connected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak model] connected in
                model?.connectionChanged(connected: connected)
            }
            .store(in: &cancellables)
    }
}
