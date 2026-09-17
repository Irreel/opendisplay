// The Design Canvas iPad app. OpenDisplay's receiver core listening on its own
// port and Bonjour type (plan ruling 1), with Draw Mode and the agent replies
// on top. It sends no input to the Mac, ever.

import SwiftUI

/// The two values that make this app its own product on the wire.
enum DesignCanvasiPad {
    /// Not 9000: a USB dial carries no service type, so only a different port
    /// keeps an OpenDisplay Mac from dialling a Design Canvas iPad.
    static let port: UInt16 = 9100
    static let serviceType = "_designcanvas._tcp"
}

@main
struct DesignCanvasApp: App {

    @StateObject private var receiverModel: ReceiverModel
    @StateObject private var canvas: CanvasModel
    /// Holds the subscriptions that feed the model; nothing else references it.
    private let adapter: ReceiverAdapter

    init() {
        let receiverModel = ReceiverModel(port: DesignCanvasiPad.port,
                                          serviceType: DesignCanvasiPad.serviceType)
        let adapter = ReceiverAdapter(receiver: receiverModel.receiver)
        let canvas = CanvasModel(receiver: adapter,
                                 nowMs: { Date().timeIntervalSince1970 * 1000 },
                                 uptime: { ProcessInfo.processInfo.systemUptime })
        // Before `start()`: the input switch must never be off while a socket
        // is up (M3).
        adapter.attach(canvas)
        self.adapter = adapter
        _receiverModel = StateObject(wrappedValue: receiverModel)
        _canvas = StateObject(wrappedValue: canvas)
    }

    var body: some Scene {
        WindowGroup {
            CanvasScreen(receiverModel: receiverModel, canvas: canvas)
        }
    }
}
