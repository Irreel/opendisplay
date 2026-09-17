// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/DesignCanvasDesktopApp.swift`.
//
// The only place the real engine is named. `@StateObject`'s autoclosure means the model — and
// with it `OpenDisplaySenderEngine`, which browses Bonjour and watches usbmuxd the moment it
// exists — is built when the scene first renders, not when this struct is created. Tests build
// `AppModel` with a `FakeSenderEngine` instead and never reach this file.

import SwiftUI

@main
struct DesignCanvasMacApp: App {
    @StateObject private var model = AppModel(engine: OpenDisplaySenderEngine())

    var body: some Scene {
        MenuBarExtra("Design Canvas", systemImage: "scribble.variable") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
