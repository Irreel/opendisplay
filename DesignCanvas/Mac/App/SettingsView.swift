// Settings, out of the popover (spec section 3): the Screen Recording grant, the server build,
// and whether the Design Canvas mod loads in every Claude Code session. Nothing here is on the board's Mac IA;
// it is what a person setting the app up needs once.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Screen Recording") {
                LabeledContent("Permission", value: model.screenRecordingGranted ? "Granted" : "Not granted")
                if !model.screenRecordingGranted {
                    Text("Design Canvas mirrors the screen, so it needs Screen Recording. Granting it in System Settings takes effect after a relaunch.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Open System Settings") { model.openScreenRecordingSettings() }
                }
            }
            // The server ships inside the app, so only a Debug build offers to point elsewhere
            // (a local server under development, or a build made without pnpm).
            #if DEBUG
            Section("Server build") {
                LabeledContent("Entry", value: model.serverEntry ?? "Not set")
                Button(model.serverEntry == nil ? "Choose\u{2026}" : "Change\u{2026}") { model.setServerBuild() }
            }
            #endif
            // X20. Off unless the user says yes, and the text says what yes means.
            Section("Claude Code") {
                Toggle("Use Design Canvas in every Claude Code session", isOn: Binding(
                    get: { model.everySessionEnabled },
                    set: { model.setEverySession($0) }
                ))
                .disabled(model.modDirectory == nil)
                Text("When on, the Design Canvas plugin loads in every Claude Code session you start, in every project, and starting a session opens this app if it isn't running. You can then start from Claude Code with no Start button. When off, only sessions started from this app use it. Turning it off removes the one entry it added to ~/.claude/settings.json.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.everySessionError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
