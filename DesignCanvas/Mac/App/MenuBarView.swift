// The popover, laid out per `DesignCanvas/spec/mac-app-ia.md` section 3: a summary line, the
// two connection rows (iPad, Claude Code) in the board's order, the project, and a footer.
// Every word, tint and action comes from `MenuPresentation`, which is tested; this file only
// draws rows and maps each `RowAction` to an `AppModel` call. Developer settings and the raw
// daemon state live in `SettingsView` and `DetailsView`, opened as windows because a
// window-style `MenuBarExtra` cannot present a sheet.

import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MenuPresentation.summary(screenRecordingGranted: model.screenRecordingGranted,
                                          iPadConnected: iPadConnected,
                                          claude: claudeRow))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            connectionSection
            Divider()
            projectSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Derived state

    private var iPadConnected: Bool { !model.devices.isEmpty }

    private var startBlocker: StartBlocker? {
        if model.selectedProject == nil { return .noProject }
        if model.serverEntry == nil { return .noServerBuild }
        return nil
    }

    private var claudeRow: RowPresentation {
        MenuPresentation.claudeCodeRow(
            display: model.sessionState.display,
            daemonGaveUp: model.daemonGaveUp,
            sessions: model.sessions.message,
            pendingUploads: model.pendingUploads,
            startBlocker: startBlocker
        )
    }

    // MARK: - Connection status

    @ViewBuilder
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.screenRecordingGranted || (model.devices.isEmpty && model.discoveredDevices.isEmpty) {
                let row = MenuPresentation.iPadPlaceholder(screenRecordingGranted: model.screenRecordingGranted)
                connectionRow(title: "iPad", detail: nil, row: row) { perform(row.action, deviceId: nil) }
            } else {
                ForEach(model.devices) { device in
                    let row = MenuPresentation.deviceRow(device)
                    connectionRow(title: device.name, detail: device.onUSB ? "USB" : "WiFi", row: row) {
                        perform(row.action, deviceId: device.id)
                    }
                }
                ForEach(model.discoveredDevices) { device in
                    let row = MenuPresentation.discoveredRow(device)
                    connectionRow(title: device.name, detail: device.transport, row: row) {
                        perform(row.action, deviceId: device.id)
                    }
                }
            }
            let claude = claudeRow
            connectionRow(title: "Claude Code", detail: nil, row: claude) { perform(claude.action, deviceId: nil) }
            sessionList
            if let help = MenuPresentation.launchHelp(model.sessionState.display) {
                Text(help)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.leading, 13)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = model.configWarning {
                Text(warning)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The connected sessions, shown only when there is a choice to make (X21: one session is
    /// simply the target and nothing is listed). A tick marks where the next sketch goes; a
    /// click moves it (X24).
    @ViewBuilder
    private var sessionList: some View {
        let message = model.sessions.message
        if model.sessionState.display == .ownedAttached, message.sessions.count > 1 {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(message.sessions) { entry in
                    Button {
                        model.selectTarget(entry.id)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .opacity(entry.id == message.target ? 1 : 0)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.folder)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(MenuPresentation.sessionDetail(entry, clock: Self.shortTime))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(entry.id == message.target ? "Sketches go to this session" : "Send sketches to this session")
                }
            }
            .padding(.leading, 13)
        }
    }

    private static let isoParsers: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [fractional, ISO8601DateFormatter()]
    }()

    private static func shortTime(_ iso: String) -> String? {
        for parser in isoParsers {
            if let date = parser.date(from: iso) {
                return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            }
        }
        return nil
    }

    /// One row: name, optional transport, state word in its tint, then the row's action (if
    /// any) on the trailing edge; the sub-line, when present, sits under the name.
    @ViewBuilder
    private func connectionRow(title: String, detail: String?, row: RowPresentation, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(row.tint))
                    .frame(width: 7, height: 7)
                // The name wins the width fight: the state is a short word (see
                // `MenuPresentation.deviceRow`), so it is the one that may truncate.
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Text(row.word)
                    .font(.callout)
                    .foregroundColor(color(row.tint))
                    .lineLimit(1)
                if let rowAction = row.action {
                    Button(label(rowAction), action: action)
                        .controlSize(.small)
                        .disabled(!row.actionEnabled || ((rowAction == .start || rowAction == .newSession) && model.startDisabled))
                }
            }
            if let subline = row.subline {
                Text(subline)
                    .font(.caption2)
                    .foregroundColor(row.tint == .secondary ? .secondary : color(row.tint))
                    .padding(.leading, 13)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func perform(_ action: RowAction?, deviceId: String?) {
        switch action {
        case .start, .newSession:
            model.startSession()
        case .retry:
            // Two dead ends share the button: a launch that timed out (start over) and a
            // supervisor that gave up (a reset restarts it, see `AppModel.resetProcesses`).
            if model.daemonGaveUp {
                Task { await model.resetProcesses() }
            } else {
                model.disconnect()
                model.startSession()
            }
        case .disconnect:
            if let deviceId { model.disconnectDevice(id: deviceId) } else { model.disconnect() }
        case .connect:
            if let deviceId { model.connectDevice(id: deviceId) }
        case .grant:
            model.openScreenRecordingSettings()
        case .details:
            open("details")
        case .none:
            break
        }
    }

    // MARK: - Project

    @ViewBuilder
    private var projectSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                if let project = model.selectedProject {
                    Text(project.lastPathComponent)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // The full folder path. When it doesn't fit, drop the head: the tail
                    // (the project folder itself) is what disambiguates.
                    Text(project.path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text("No project selected")
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Menu("Change\u{2026}") {
                ForEach(model.recentProjects.prefix(3), id: \.self) { url in
                    Button(url.lastPathComponent) { model.selectRecent(url) }
                }
                if !model.recentProjects.isEmpty { Divider() }
                Button("Open Folder\u{2026}") { model.pickProject() }
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Details\u{2026}") { open("details") }
            Button("Settings\u{2026}") { open("settings") }
            Spacer()
            Button("Quit") { model.quit() }
        }
        .controlSize(.small)
    }

    // MARK: - Helpers

    /// A menu-bar app has no key window, so the new window must be brought forward by hand.
    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func color(_ tint: MenuTint) -> Color {
        switch tint {
        case .secondary: return .secondary
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        }
    }

    private func label(_ action: RowAction) -> String {
        switch action {
        case .start: return "Start"
        case .newSession: return "New Session"
        case .retry: return "Retry"
        case .disconnect: return "Disconnect"
        case .connect: return "Connect"
        case .grant: return "Grant"
        case .details: return "Details\u{2026}"
        }
    }
}
