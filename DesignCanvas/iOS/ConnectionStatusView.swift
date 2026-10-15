// The details behind the session list's "Connection details…" (P2): what the
// receiver thinks it is doing, what the Mac said about its channel, the
// connection parameters, the last notice, and the log. The at-a-glance half of
// P1 is the project pill and its session list, in `ProjectPill.swift`.

import SwiftUI

/// How one session reads in a list (X25): its folder, then what tells it from
/// another session in the same folder: the title the user gave it, or when it
/// started; its branch; when it last replied.
enum SessionText {
    static func line(_ entry: CanvasSessionEntry) -> String {
        ([entry.folder] + details(entry)).joined(separator: " \u{00B7} ")
    }

    /// Everything but the folder, for a row that shows the folder on its own line.
    static func detail(_ entry: CanvasSessionEntry) -> String {
        details(entry).joined(separator: " \u{00B7} ")
    }

    private static func details(_ entry: CanvasSessionEntry) -> [String] {
        var parts: [String] = []
        if let title = entry.title {
            parts.append(title)
        } else if let started = shortTime(entry.startedAt) {
            parts.append("started \(started)")
        }
        if let branch = entry.branch { parts.append(branch) }
        if let lastReplyAt = entry.lastReplyAt, let replied = shortTime(lastReplyAt) {
            parts.append("replied \(replied)")
        }
        return parts
    }

    private static let parsers: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [fractional, ISO8601DateFormatter()]
    }()

    static func shortTime(_ iso: String) -> String? {
        for parser in parsers {
            if let date = parser.date(from: iso) {
                return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            }
        }
        return nil
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
            case .up: return .canvasSuccessMark
            case .warning: return .canvasWarningMark
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
                    if model.waitingAtMac {
                        LabeledContent("Claude Code", value: CanvasSessionState.waiting.title)
                    }
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

                if model.sessions.sessions.count > 1 {
                    Section {
                        ForEach(model.sessions.sessions) { entry in
                            Button {
                                model.selectSession(entry.id)
                            } label: {
                                HStack {
                                    Text(SessionText.line(entry))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if entry.id == model.sessions.target {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Claude Code sessions")
                    } footer: {
                        Text(model.sessions.needsPick
                             ? "The session your sketches were going to has ended. Choose where the next one goes."
                             : "The next sketch goes to the ticked session. One already sent stays where it was sent.")
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
        case .existing: return "Another session"
        case .detached: return "Detached"
        case .none: return receiver.connected ? "No session" : "Unknown"
        }
    }

}
