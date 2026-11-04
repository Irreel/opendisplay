// The Design Canvas iPad app: it listens for the Mac, shows its screen, and is
// the sketchpad, with the agent's replies on top. It sends no input to the
// Mac, ever.

import SwiftUI

@main
struct DesignCanvasApp: App {

    @StateObject private var receiverController: ReceiverController
    @StateObject private var canvas: CanvasModel
    /// Holds the subscriptions that feed the model; nothing else references it.
    private let adapter: ReceiverAdapter

    init() {
        let receiverController = ReceiverController()
        let adapter = ReceiverAdapter(receiver: receiverController.receiver)
        let canvas = CanvasModel(receiver: adapter,
                                 nowMs: { Date().timeIntervalSince1970 * 1000 },
                                 uptime: { ProcessInfo.processInfo.systemUptime })
        // Before `start()`, so no message can arrive with nowhere to go.
        adapter.attach(canvas)
        self.adapter = adapter
        _receiverController = StateObject(wrappedValue: receiverController)
        _canvas = StateObject(wrappedValue: canvas)
    }

    var body: some Scene {
        WindowGroup {
            CanvasScreen(receiverModel: receiverController, canvas: canvas)
        }
    }
}
