// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/DesignCanvasDesktopApp.swift`.
//
// The only place the real engine is named. `@StateObject`'s autoclosure means the model — and
// with it `OpenDisplaySenderEngine`, which browses Bonjour and watches usbmuxd the moment it
// exists — is built when the scene first renders, not when this struct is created. Tests build
// `AppModel` with a `FakeSenderEngine` instead and never reach this file.
//
// The menu-bar symbol carries the app's state (spec section 3), so the one thing visible
// without a click says whether both hops are up. `pencil.tip.crop.circle` has the four
// variants the four states need; `scribble.variable` had none.

import SwiftUI

@main
struct DesignCanvasMacApp: App {
    @StateObject private var model = AppModel(engine: OpenDisplaySenderEngine())

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: symbol(for: iconState))
        }
        .menuBarExtraStyle(.window)

        Window("Design Canvas Details", id: "details") {
            DetailsView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Design Canvas Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }

    private var iconState: MenuIcon {
        let startBlocker: StartBlocker? = model.selectedProject == nil ? .noProject : (model.serverEntry == nil ? .noServerBuild : nil)
        let claude = MenuPresentation.claudeCodeRow(
            display: model.sessionState.display,
            daemonGaveUp: model.daemonGaveUp,
            secondSubscriber: model.sessionState.secondSubscriber,
            pendingUploads: model.pendingUploads,
            startBlocker: startBlocker
        )
        return MenuPresentation.icon(iPadConnected: !model.devices.isEmpty,
                                     claude: claude,
                                     screenRecordingGranted: model.screenRecordingGranted)
    }

    private func symbol(for state: MenuIcon) -> String {
        switch state {
        case .idle: return "pencil.tip.crop.circle"
        case .ready: return "pencil.tip.crop.circle.fill"
        case .partial: return "pencil.tip.crop.circle.badge.plus"
        case .attention: return "pencil.tip.crop.circle.badge.minus"
        }
    }
}
