// Developer-facing settings, out of the popover (spec section 3): the Screen Recording grant,
// the server build, and the project's `.mcp.json` entry. Nothing here is on the board's Mac IA;
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
            Section("Project configuration") {
                if model.selectedProject == nil {
                    Text("No project selected").foregroundColor(.secondary)
                } else if model.needsMcpUpdate {
                    Text("This project's .mcp.json has an outdated design-canvas entry.")
                        .foregroundColor(.orange)
                    Button("Update .mcp.json entry") { model.updateMcpEntry() }
                } else {
                    Text(".mcp.json entry is current").foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
