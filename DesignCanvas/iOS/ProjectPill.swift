// Where the next sketch goes, at a glance (P1): the project of the Claude Code
// session it is bound for. Tapping it lists every session the Mac is connected
// to with what each is doing, and that list is also where the designer learns
// that there is none. The iPad-to-Mac hop has no place here: when it is down
// there is no picture, and the whole screen says so.

import SwiftUI

struct ProjectPill: View {

    @ObservedObject var model: CanvasModel
    let onConnectionDetails: () -> Void

    @State private var showList = false
    /// Set by the list's last row. The sheet may only go up once the popover
    /// is down, or the presentation is dropped.
    @State private var wantsDetails = false

    var body: some View {
        Button {
            showList = true
        } label: {
            HStack(spacing: 4) {
                // The dot, not just the colour, says the pill needs a look
                // (WCAG 1.4.1).
                if needsAttention {
                    Circle()
                        .fill(Color.canvasWarningMark)
                        .frame(width: 8, height: 8)
                        .padding(.trailing, 2)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(needsAttention ? Color.canvasWarningText : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.canvasSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 260)
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .canvasGlass(in: Capsule())
        .accessibilityLabel("Claude Code session: \(title)")
        .accessibilityHint("Lists the connected sessions")
        .popover(isPresented: $showList, arrowEdge: .top) {
            SessionList(model: model) {
                wantsDetails = true
                showList = false
            } onPick: {
                showList = false
            }
            .onDisappear {
                guard wantsDetails else { return }
                wantsDetails = false
                onConnectionDetails()
            }
        }
    }

    private var needsAttention: Bool { model.sessions.needsPick || !model.hasClaudeSession }

    private var title: String {
        if model.sessions.needsPick { return "Choose a session" }
        if let entry = model.targetSession { return entry.folder }
        // A Mac that predates the session list still names its project.
        if model.hasClaudeSession { return model.project ?? "Claude Code" }
        return "No session"
    }
}

extension CanvasSessionState {
    /// The state as the session list words it.
    var title: String {
        switch self {
        case .idle: return "Ready"
        case .busy: return "Busy"
        case .waiting: return "Waiting for reply at desktop"
        }
    }

    /// The dot before the state.
    var color: Color {
        switch self {
        case .idle: return .canvasSuccessMark
        case .busy: return .red
        case .waiting: return .canvasWarningMark
        }
    }

    /// The state's words: dark enough to read as text.
    var textColor: Color {
        switch self {
        case .idle: return .canvasSecondary
        case .busy: return .canvasDangerText
        case .waiting: return .canvasWarningText
        }
    }
}

/// The connected sessions (X24, X25), each with its state, a tick on the one
/// the next sketch goes to, and the way to the connection details.
private struct SessionList: View {

    @ObservedObject var model: CanvasModel
    let onConnectionDetails: () -> Void
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CLAUDE CODE SESSIONS")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.canvasSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

            if model.sessions.sessions.isEmpty {
                empty
            } else {
                ForEach(model.sessions.sessions) { entry in
                    Button {
                        model.selectSession(entry.id)
                        onPick()
                    } label: {
                        row(entry)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().padding(.top, 6)

            Button(action: onConnectionDetails) {
                Text("Connection details\u{2026}")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.canvasAccentText)
        }
        .frame(width: 420)
        .padding(.bottom, 4)
    }

    private func row(_ entry: CanvasSessionEntry) -> some View {
        let isTarget = entry.id == model.sessions.target
        let detail = SessionText.detail(entry)
        return HStack(spacing: 12) {
            ClaudeMark()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.folder)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(entry.state.color)
                        .frame(width: 8, height: 8)
                    Text(entry.state.title)
                        .foregroundStyle(entry.state.textColor)
                    if !detail.isEmpty {
                        Text("\u{00B7}  \(detail)")
                            .foregroundStyle(Color.canvasSecondary)
                    }
                }
                .font(.footnote)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .opacity(isTarget ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.folder), \(entry.state.title)\(detail.isEmpty ? "" : ", \(detail)")")
        .accessibilityAddTraits(isTarget ? [.isSelected, .isButton] : [.isButton])
    }

    @ViewBuilder
    private var empty: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.hasClaudeSession {
                // An older Mac: it reports one session on its ping and lists none.
                Text(model.project ?? "Claude Code")
                    .font(.subheadline.weight(.medium))
                Text("Connected")
                    .font(.footnote)
                    .foregroundStyle(Color.canvasSecondary)
            } else {
                Text("Not connected")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.canvasWarningText)
                Text("Start Claude Code on the Mac with the Design Canvas mod. It shows up here on its own.")
                    .font(.footnote)
                    .foregroundStyle(Color.canvasSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// A twelve-ray spark in Claude's orange, marking a row as a Claude Code
/// session. Drawn here, not shipped as artwork: it stands in for the mark and
/// is not a copy of it.
struct ClaudeMark: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            Path { path in
                for ray in 0..<12 {
                    let angle = (Double(ray) * 30 - 90) * .pi / 180
                    let outer = side * (ray.isMultiple(of: 2) ? 0.44 : 0.37)
                    let inner = side * 0.12
                    path.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
                    path.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
                }
            }
            .stroke(Color(red: 0.851, green: 0.467, blue: 0.341),
                    style: StrokeStyle(lineWidth: side * 0.105, lineCap: .round))
        }
    }
}
