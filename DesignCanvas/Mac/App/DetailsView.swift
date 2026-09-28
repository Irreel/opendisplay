// The raw state behind the popover's two rows (spec section 3, Details window): the classifier's
// own wording, the daemon's health fields, the iPads, and Reset. This is where "port 47100" and
// "channel" belong — the popover says "Blocked" and points here.

import SwiftUI

struct DetailsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Session") {
                LabeledContent("State", value: model.sessionState.display.statusText)
                if model.sessionState.secondSubscriber {
                    Text("Two channel connections detected").foregroundColor(.orange)
                }
                if model.daemonGaveUp {
                    Text("Daemon stopped retrying \u{2014} port may be in use").foregroundColor(.orange)
                }
            }
            Section("Daemon") {
                switch model.lastProbeResult {
                case .healthy(let h):
                    LabeledContent("Status", value: h.status)
                    LabeledContent("Version", value: h.version)
                    LabeledContent("PID", value: h.pid.map(String.init) ?? "\u{2014}")
                    LabeledContent("Port", value: h.port.map(String.init) ?? "\u{2014}")
                    LabeledContent("Instance", value: h.instanceId ?? "\u{2014}")
                    LabeledContent("Started", value: h.startedAt ?? "\u{2014}")
                    LabeledContent("Channels", value: String(h.channelCount ?? (h.channelAttached ? 1 : 0)))
                    LabeledContent("Channel attached", value: h.channelAttachedAt ?? "\u{2014}")
                case .refused:
                    LabeledContent("Probe", value: "Connection refused (nothing listening)")
                case .timedOut:
                    LabeledContent("Probe", value: "Timed out")
                case .badStatus(let code):
                    LabeledContent("Probe", value: "HTTP \(code)")
                case .foreignResponse:
                    LabeledContent("Probe", value: "Something else answered on the port")
                }
                LabeledContent("Owned by this app", value: model.sessionState.daemon == .owned ? "Yes" : "No")
            }
            Section("iPads") {
                if model.devices.isEmpty {
                    Text("None connected").foregroundColor(.secondary)
                }
                ForEach(model.devices) { device in
                    LabeledContent(device.name, value: "\(device.status) \u{00B7} \(device.onUSB ? "USB" : "WiFi") \u{00B7} \(device.id)")
                }
                ForEach(model.discoveredDevices) { device in
                    LabeledContent(device.name, value: "Discovered \u{00B7} \(device.transport) \u{00B7} \(device.id)")
                }
                LabeledContent("Sketches waiting to send", value: String(model.pendingUploads))
            }
            if let warning = model.configWarning {
                Section("Last error") {
                    Text(warning).foregroundColor(.red).textSelection(.enabled)
                }
            }
            Section("Reset") {
                Text("Stops Design Canvas helper processes. May detach an existing Claude Code channel. Never quits Claude Code or edits your files.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Button("Reset Design Canvas Processes") { Task { await model.resetProcesses() } }
                        .disabled(model.isResetting)
                    if model.sessionState.display == .existingSessionDetected {
                        Button("Start New After Reset") { Task { await model.startNewAfterReset() } }
                            .disabled(model.isResetting)
                    }
                }
                if let outcome = model.lastResetOutcome {
                    // The unknown occupant we refused to touch is the more important safety
                    // fact, so it wins over a "some processes didn't stop" report.
                    if outcome.refusedUnknownOccupant {
                        Text("Port 47100 is held by an unknown process \u{2014} not touched.").foregroundColor(.orange)
                    } else if !outcome.failedPids.isEmpty {
                        Text("Some processes did not stop (see Activity Monitor).").foregroundColor(.red)
                    } else {
                        Text("Reset complete.").foregroundColor(.secondary)
                    }
                }
            }
            Section("Session end") {
                Text("Disconnect only stops this app tracking the session. Claude Code keeps running; quit it in its Terminal to end the session.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Logs") {
                Button("Open Logs Folder") {
                    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
                    NSWorkspace.shared.open(logs.appendingPathComponent("OpenDisplay"))
                }
                Text("App: ~/Library/Logs/OpenDisplay/opendisplay.log \u{00B7} Daemon: ~/Library/Logs/DesignCanvas/server.log")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
    }
}
