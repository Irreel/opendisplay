// Both hops and the project, at a glance (P1), and the details behind a tap
// (P2): what the receiver thinks it is doing, what the Mac said about its
// channel, the connection parameters, the last notice, and the log.

import SwiftUI

struct ConnectionStatusView: View {

    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var model: CanvasModel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                StatusDot(state: linkState)
                    .accessibilityLabel("\(deviceKind) to Mac: \(linkState.title)")
                StatusDot(state: channelState)
                    .accessibilityLabel("Mac to Claude Code: \(channelState.title)")
                Text(model.project ?? "unselected")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(model.project == nil ? .secondary : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows connection details")
    }

    private var linkState: StatusDot.State {
        guard receiver.connected else { return .down }
        return receiver.canvas.macSupportsCanvas ? .up : .warning
    }

    private var channelState: StatusDot.State {
        switch model.channel {
        case .attached: return .up
        case .detached: return .warning
        case .none: return .down
        }
    }
}

struct StatusDot: View {
    enum State {
        case up, warning, down

        var title: String {
            switch self {
            case .up: return "working"
            case .warning: return "not ready"
            case .down: return "not connected"
            }
        }

        var color: Color {
            switch self {
            case .up: return .green
            case .warning: return .orange
            case .down: return .secondary
            }
        }
    }

    let state: State

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 10, height: 10)
    }
}

/// The modal behind the status panel (P2).
struct ConnectionDetailView: View {

    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var model: CanvasModel
    let port: UInt16
    let serviceType: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("\(deviceKind) to Mac", value: receiver.status)
                    LabeledContent("Mac to Claude Code", value: channelDescription)
                    LabeledContent("Project", value: model.project ?? "unselected")
                    if receiver.videoSize != .zero {
                        LabeledContent("Mirror",
                                       value: "\(Int(receiver.videoSize.width))×\(Int(receiver.videoSize.height)) @ \(receiver.fps) fps")
                    }
                } header: {
                    Text("Status")
                } footer: {
                    if receiver.connected && !receiver.canvas.macSupportsCanvas {
                        Text("The Mac connected to this \(deviceKind) is not running Design Canvas, so Draw Mode is unavailable. It mirrors the screen and nothing else.")
                    }
                }

                if let notice = model.notice {
                    Section("Last message") {
                        Text(notice.text)
                    }
                }

                Section {
                    LabeledContent("Listening", value: "Port \(port)")
                    LabeledContent("Service", value: serviceType)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Design Canvas listens on its own port and Bonjour type, so an OpenDisplay Mac never dials this app and Design Canvas never dials an OpenDisplay \(deviceKind).")
                }

                Section {
                    NavigationLink {
                        DiagnosticsLogView()
                    } label: {
                        Label("Connection log", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("What this \(deviceKind) saw while connecting. No screen content, and nothing leaves the \(deviceKind) unless you share it.")
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var channelDescription: String {
        switch model.channel {
        case .attached: return "Attached"
        case .detached: return "Detached"
        case .none: return receiver.connected ? "No session" : "Unknown"
        }
    }

}
