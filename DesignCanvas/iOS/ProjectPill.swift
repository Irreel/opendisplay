// Where the next sketch goes, at a glance (P1): the project of the Claude Code
// session it is bound for. Tapping it lists every session the Mac is connected
// to with what each is doing, and that list is also where the designer learns
// that there is none. The iPad-to-Mac hop has no place here: when it is down
// there is no picture, and the whole screen says so.
//
// The list is the pill opened (`MorphMenu`; Figma v3.1, M8): the session's
// name and status dot travel from the pill into the list's row for that
// session. The sketch Send takes away lands here too (`SentSketchCard`).

import SwiftUI
import UIKit

struct ProjectPill: View {

    @ObservedObject var model: CanvasModel
    /// The widest the pill may be; it truncates the folder's name to fit.
    var maxWidth: CGFloat = 260
    /// The menu's width, and the most it may be tall before its rows scroll.
    var menuSize = CGSize(width: 420, height: 600)
    /// Sketches that have landed in the pill, so it can answer each.
    var landings = 0
    @Binding var isOpen: Bool
    let onConnectionDetails: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The name has the row's weight: it changes just before it lands. Its
    /// own state, so the fade's timing never reaches the name's travel.
    @State private var landed = false

    var body: some View {
        MorphMenu(isOpen: $isOpen, menuSize: menuSize,
                  accessibilityLabel: "Claude Code session: \(title)",
                  accessibilityHint: "Lists the connected sessions") {
            label
        } menu: {
            SessionList(model: model, travels: travels) {
                isOpen = false
                onConnectionDetails()
            } onPick: {
                isOpen = false
            }
        } travellers: { frames in
            travellers(frames)
        }
        .modifier(LandingPulse(landings: landings))
        .onChange(of: isOpen) { open in
            let weight = reduceMotion ? nil : Animation.easeInOut(duration: 0.08).delay(open ? 0.29 : 0.05)
            withAnimation(weight) { landed = open }
        }
    }

    private var label: some View {
        CappedWidth(maxWidth: maxWidth) {
            HStack(spacing: 4) {
                // The dot, not just the colour, says the pill needs a look
                // (WCAG 1.4.1); with a session, it is that session's state.
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .morphFrame(Part.pillDot)
                        .opacity(travels ? 0 : 1)
                        .padding(.trailing, 2)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(needsAttention ? Color.canvasWarningText : .primary)
                    .lineLimit(1)
                    .morphFrame(Part.pillName)
                    .opacity(travels ? 0 : 1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.canvasSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func travellers(_ frames: [String: CGRect]) -> some View {
        if travels, let fromName = frames[Part.pillName], let toName = frames[Part.rowName] {
            let name = isOpen ? toName : fromName
            // The pill's weight on the way, the row's for the landing. Each
            // is scaled to the other's size on the way, so at the swap the
            // two only differ in weight.
            let ratio = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
                / UIFont.preferredFont(forTextStyle: .headline).pointSize
            ZStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(width: fromName.width, alignment: .leading)
                    .scaleEffect(isOpen ? ratio : 1, anchor: .leading)
                    .opacity(landed ? 0 : 1)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .frame(width: toName.width, alignment: .leading)
                    .scaleEffect(isOpen ? 1 : 1 / ratio, anchor: .leading)
                    .opacity(landed ? 1 : 0)
            }
            .travelling(to: CGPoint(x: name.minX, y: name.midY))
        }
        if travels, let dotColor, let fromDot = frames[Part.pillDot], let toDot = frames[Part.rowDot] {
            let dot = isOpen ? toDot : fromDot
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .travelling(to: CGPoint(x: dot.minX, y: dot.midY))
        }
    }

    /// The name and dot carry over into the menu when the pill names a
    /// session that has a row there. With Reduce Motion they fade with the
    /// rest instead.
    private var travels: Bool {
        !reduceMotion && !needsAttention && model.targetSession != nil
    }

    private var needsAttention: Bool { model.sessions.needsPick || !model.hasClaudeSession }

    private var dotColor: Color? {
        needsAttention ? .canvasWarningMark : model.targetSession?.state.color
    }

    private var title: String {
        if let entry = model.targetSession, !model.sessions.needsPick { return entry.folder }
        // A Mac that predates the session list still names its project.
        if model.hasClaudeSession && !model.sessions.needsPick { return model.project ?? "Claude Code" }
        // With none to send to, as with several and none chosen, the pill
        // asks for one; its menu says why (Figma v3.1, 01c and 03a).
        return "Choose a session"
    }

    /// The parts that carry over into the menu.
    fileprivate enum Part {
        static let pillName = "pillName"
        static let pillDot = "pillDot"
        static let rowName = "rowName"
        static let rowDot = "rowDot"
    }
}

/// As wide as what it holds, but never wider than `maxWidth`: the name
/// truncates rather than the pill growing past it. A plain `frame(maxWidth:)`
/// would stretch a short name to the cap.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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
    /// The target's name and dot are drawn by the pill, on their way in.
    let travels: Bool
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
                // The rows scroll only when there are more than the screen
                // is tall for.
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
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
        .padding(.bottom, 4)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
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
    }

    private func row(_ entry: CanvasSessionEntry) -> some View {
        let isTarget = entry.id == model.sessions.target
        let carried = travels && isTarget
        let detail = SessionText.detail(entry)
        return HStack(spacing: 12) {
            ClaudeMark()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.folder)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .morphFrame(isTarget ? ProjectPill.Part.rowName : nil)
                    .opacity(carried ? 0 : 1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(entry.state.color)
                        .frame(width: 8, height: 8)
                        .morphFrame(isTarget ? ProjectPill.Part.rowDot : nil)
                        .opacity(carried ? 0 : 1)
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
