// The Mac's half of pairing: a small window with the code, shown on top of
// whatever is in front, since a menu-bar app has no window of its own to
// carry the question. The iPad shows the same code; the user confirms on both
// (Bluetooth's numeric comparison).

import AppKit
import SwiftUI

@MainActor
final class PairingPanel {
    static let shared = PairingPanel()

    private var window: NSPanel?
    private var shownID: String?

    /// Shows the prompt, replaces it, or takes it down for nil.
    func show(_ prompt: PairingPrompt?, model: AppModel) {
        guard let prompt else {
            window?.close()
            window = nil
            shownID = nil
            return
        }
        guard prompt.id != shownID || window == nil else { return }
        window?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Pair with \(prompt.deviceName)"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PairingView(prompt: prompt) { accept in
            model.answerPairing(accept: accept)
        })
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        window = panel
        shownID = prompt.id
    }
}

private struct PairingView: View {
    let prompt: PairingPrompt
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair with \u{201C}\(prompt.deviceName)\u{201D}?")
                .font(.headline)
            Text(prompt.code)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .accessibilityLabel("Code \(prompt.code.map { String($0) }.joined(separator: " "))")
            Text("Check that the iPad shows the same code, then tap Pair on both. If the codes differ, cancel.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { answer(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
