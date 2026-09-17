// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/MenuBarView.swift`.
//
// The capture section is gone (no hotkey, no "Capture frontmost window", no last-capture label)
// and so is the iPad URL row — the iPad reaches the Mac over the OpenDisplay connection, not
// over LAN HTTP, so there is no URL to show. In their place: the device list the engine
// publishes, and a Screen Recording row, which is the one permission the sender needs.
//
// Every branch here reads a value that is tested elsewhere (`SessionStateClassifier`,
// `DisplayState.statusText`, `AppModel.devices`); this file just draws them.

import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            daemonSection
            resetSection
            Divider()
            devicesSection
            Divider()
            screenRecordingSection
            Divider()
            serverBuildSection
            Divider()
            projectSection
            Divider()
            sessionSection
            Divider()
            Button("Quit") { model.quit() }
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder
    private var daemonSection: some View {
        switch model.sessionState.daemon {
        case .none:
            Text(DisplayState.noDaemon.statusText)
                .foregroundColor(DisplayState.noDaemon.statusTint)
        case .unknownOccupant:
            Text(DisplayState.portOccupiedUnknown.statusText)
                .foregroundColor(DisplayState.portOccupiedUnknown.statusTint)
        case .owned, .foreign:
            Text("Daemon: running")
                .foregroundColor(.green)
        }
        if model.daemonGaveUp {
            Text("Daemon stopped retrying \u{2014} port may be in use")
                .font(.caption2)
                .foregroundColor(.orange)
        }
    }

    /// Offers a way out of "existing session"/"foreign daemon"/"unknown occupant" states without
    /// silently killing Claude Code (spec section 6): reset only ever stops argv-verified
    /// Design Canvas helper processes (see `ProcessResetService`).
    @ViewBuilder
    private var resetSection: some View {
        switch model.sessionState.display {
        case .existingSessionDetected, .foreignDaemon, .portOccupiedUnknown:
            VStack(alignment: .leading, spacing: 4) {
                Button("Reset Design Canvas Processes") { Task { await model.resetProcesses() } }
                    .disabled(model.isResetting)
                Text("Stops Design Canvas helper processes. May detach an existing Claude Code channel. Never quits Claude Code or edits your files.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if model.sessionState.display == .existingSessionDetected {
                    Button("Start New After Reset") { Task { await model.startNewAfterReset() } }
                        .disabled(model.isResetting)
                }
                if let outcome = model.lastResetOutcome {
                    resetOutcomeStatus(outcome)
                }
            }
        case .noDaemon, .daemonOnly, .launchPending, .launchTimedOut, .ownedAttached:
            EmptyView()
        }
    }

    /// One status line, priority order: an unknown occupant we refused to touch is the more
    /// important safety fact, so it wins over a "some processes didn't stop" report.
    @ViewBuilder
    private func resetOutcomeStatus(_ outcome: ResetOutcome) -> some View {
        if outcome.refusedUnknownOccupant {
            Text("Port 47100 is held by an unknown process \u{2014} not touched.")
                .font(.caption2)
                .foregroundColor(.orange)
        } else if !outcome.failedPids.isEmpty {
            Text("Some processes did not stop (see Activity Monitor).")
                .font(.caption2)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        Text("iPads")
            .font(.caption)
            .foregroundColor(.secondary)
        if model.devices.isEmpty {
            Text("No iPad connected \u{2014} open Design Canvas on the iPad")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            ForEach(model.devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(device.status)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(device.onUSB ? "USB" : "WiFi")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var screenRecordingSection: some View {
        HStack {
            Text("Screen Recording: \(model.screenRecordingGranted ? "granted" : "not granted")")
                .font(.caption)
                .foregroundColor(model.screenRecordingGranted ? .green : .red)
            if !model.screenRecordingGranted {
                Spacer()
                Button("Grant") { model.openScreenRecordingSettings() }
            }
        }
        if !model.screenRecordingGranted {
            Text("Design Canvas mirrors the screen, so it needs Screen Recording. Granting it in System Settings takes effect after a relaunch.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var serverBuildSection: some View {
        HStack {
            Text("Server build: \(model.serverEntry == nil ? "unset" : "set")")
                .font(.caption)
            Spacer()
            Button(model.serverEntry == nil ? "Set server build\u{2026}" : "Set\u{2026}") { model.setServerBuild() }
        }
        if let serverEntry = model.serverEntry {
            Text(serverEntry)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var projectSection: some View {
        Text("Recent projects")
            .font(.caption)
            .foregroundColor(.secondary)
        if model.recentProjects.isEmpty {
            Text("None")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            ForEach(model.recentProjects, id: \.self) { url in
                Button(url.lastPathComponent) { model.selectRecent(url) }
                    .buttonStyle(.link)
            }
        }
        Button("Open Project\u{2026}") { model.pickProject() }
        if let project = model.selectedProject {
            Text("Selected: \(project.path)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        Button("Start session") { model.startSession() }
            .disabled(model.selectedProject == nil || model.serverEntry == nil || model.startDisabled)
        if model.selectedProject == nil {
            Text("No project selected")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if model.serverEntry == nil {
            Text("No server build set")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        if model.needsMcpUpdate {
            Text("This project's .mcp.json has an outdated design-canvas entry.")
                .font(.caption)
                .foregroundColor(.orange)
            Button("Update .mcp.json entry") { model.updateMcpEntry() }
        }
        if let warning = model.configWarning {
            Text(warning)
                .font(.caption)
                .foregroundColor(.red)
        }
        sessionStatus
        if model.sessionState.secondSubscriber {
            Text("\u{26A0}\u{FE0E} Two channel connections detected")
                .font(.caption)
                .foregroundColor(.orange)
        }
        if model.sessionStarted {
            Button("Disconnect") { model.disconnect() }
            Text("Disconnect only stops this app tracking the session \u{2014} Claude Code keeps running. Quit it in its Terminal to end the session.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// Driven by `sessionState.display` (re-verified every poll), so it distinguishes a session
    /// this app launched from one it merely observes, and auto-clears when the user quits Claude
    /// Code. `noDaemon`/`portOccupiedUnknown` are already covered by `daemonSection` above, so
    /// this row stays empty for those to avoid showing the same fact twice.
    @ViewBuilder
    private var sessionStatus: some View {
        switch model.sessionState.display {
        case .noDaemon, .portOccupiedUnknown:
            EmptyView()
        default:
            Text(model.sessionState.display.statusText)
                .font(.caption)
                .foregroundColor(model.sessionState.display.statusTint)
        }
    }
}
