// The one floating panel: Mirror, Blank and Draw between sketches, the drawing
// tools in Draw Mode. It is the same view in both, so entering Draw Mode
// stretches it into the tool palette where it stands, and leaving shrinks it
// back. The designer can drag it to any edge (`PanelEdge`); on a side edge its
// controls run top to bottom. It drags from anywhere; its grabber shows only
// while it is being moved, and for a moment when the panel first appears, on
// the side of the panel that faces its screen edge.
//
// The surface is Liquid Glass where the system has it and the frosted material
// everywhere else, behind `canvasGlass(in:)`.

import SwiftUI

extension View {
    /// The chrome's surface: Liquid Glass on iOS 26, which bends as the shape
    /// under it changes size; the regular material with a soft shadow before.
    /// Either way a 92% fill sits on the glass, so the chrome reads over any
    /// picture.
    @ViewBuilder
    func canvasGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            background(Color.canvasSurface, in: shape)
                .glassEffect(.regular.interactive(), in: shape)
        } else {
            background(Color.canvasSurface, in: shape)
                .background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
    }
}

/// A 36-point round button holding one symbol. Every control in the chrome is
/// one of these, so each needs an accessibility label from its caller.
struct PanelIconButton: View {
    enum Emphasis { case plain, selected, prominent }

    let systemImage: String
    var emphasis: Emphasis = .plain
    var tint: Color = .primary
    var size: CGFloat = 36
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        guard isEnabled else { return Color(.tertiaryLabel) }
        switch emphasis {
        case .plain: return tint
        case .selected: return Color(.systemBackground)
        case .prominent: return .white
        }
    }

    private var background: Color {
        switch emphasis {
        case .plain: return .clear
        // The label colour by name: `.primary` goes grey inside glass.
        case .selected: return isEnabled ? Color(.label) : Color(.tertiarySystemFill)
        case .prominent: return isEnabled ? .accentColor : Color(.tertiarySystemFill)
        }
    }
}

/// The hairline between groups of controls, turned to suit the panel.
struct PanelDivider: View {
    let vertical: Bool

    var body: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: vertical ? 22 : 1, height: vertical ? 1 : 22)
            .accessibilityHidden(true)
    }
}

struct ControlPanel<Content: View>: View {

    @Binding var edge: PanelEdge
    /// The safe area the panel docks inside, in the "chrome" coordinate space.
    let containerSize: CGSize
    @ViewBuilder let content: (_ vertical: Bool) -> Content

    @GestureState private var drag = CGSize.zero
    /// True for a moment after the panel first appears, so the grabber is
    /// seen once before it hides.
    @State private var hinting = false

    private static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    /// The grabber is feedback, not a precondition: the panel drags from
    /// anywhere, and the grabber shows only while it is being moved.
    private var showsHandle: Bool { drag != .zero || hinting }

    var body: some View {
        let vertical = edge.isVertical
        let controls = vertical
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        // The grabber runs along the panel, on the side that faces the screen
        // edge it is docked to: above a row at the top, below it at the
        // bottom, left of a column on the left, right of it on the right.
        let frame = vertical
            ? AnyLayout(HStackLayout(spacing: 4))
            : AnyLayout(VStackLayout(spacing: 4))
        let handleFirst = edge == .top || edge == .leading

        frame {
            if showsHandle && handleFirst {
                handle(vertical: vertical)
                    .transition(.opacity)
            }
            controls { content(vertical) }
            if showsHandle && !handleFirst {
                handle(vertical: vertical)
                    .transition(.opacity)
            }
        }
        .padding(4)
        .canvasGlass(in: Self.shape)
        .contentShape(Self.shape)
        .overlay(alignment: .top) { positionControl }
        // Moving the panel must not need a drag: a long press offers the
        // four edges.
        .contextMenu {
            ForEach(PanelEdge.menuOrder, id: \.self) { target in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { edge = target }
                } label: {
                    if target == edge {
                        Label("Move to \(target.spokenName.lowercased())", systemImage: "checkmark")
                    } else {
                        Text("Move to \(target.spokenName.lowercased())")
                    }
                }
            }
        }
        .offset(drag)
        // High priority with a minimum distance: a tap still reaches the
        // button under it, a drag that starts on a button moves the panel.
        .highPriorityGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .named("chrome"))
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    let rest = edge.restingCenter(in: containerSize, inset: 40)
                    let dropped = CGPoint(x: rest.x + value.translation.width,
                                          y: rest.y + value.translation.height)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        edge = PanelEdge.nearest(to: dropped, in: containerSize)
                    }
                }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: drag == .zero)
        .animation(.easeInOut(duration: 0.25), value: hinting)
        .task {
            hinting = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            hinting = false
        }
    }

    private func handle(vertical: Bool) -> some View {
        Capsule()
            .fill(Color.canvasSecondary)
            .frame(width: vertical ? 5 : 36, height: vertical ? 36 : 5)
            .accessibilityHidden(true)
    }

    /// The grabber comes and goes, so VoiceOver gets a control that is always
    /// there: nothing to see, and the four edges as its actions.
    private var positionControl: some View {
        Color.clear
            .frame(width: 36, height: 8)
            .accessibilityElement()
            .accessibilityLabel("Panel position")
            .accessibilityValue(edge.spokenName)
            .accessibilityHint("Drag the panel to another edge of the screen")
            .accessibilityAction(named: "Move to top") { edge = .top }
            .accessibilityAction(named: "Move to bottom") { edge = .bottom }
            .accessibilityAction(named: "Move to left") { edge = .leading }
            .accessibilityAction(named: "Move to right") { edge = .trailing }
    }
}

extension PanelEdge {
    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    fileprivate static let menuOrder: [PanelEdge] = [.top, .bottom, .leading, .trailing]

    fileprivate var spokenName: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .leading: return "Left"
        case .trailing: return "Right"
        }
    }
}

// MARK: - What the panel holds

/// Between sketches: the surface (B1) and the way into Draw Mode (P3).
struct LiveControls: View {
    @ObservedObject var model: CanvasModel
    @Binding var storedSurface: String
    let vertical: Bool
    let onDraw: () -> Void

    private var isBlank: Bool { storedSurface == CanvasSurface.blank.rawValue }

    /// The surface can change only on a Mac that can take a blank sketch (B3)
    /// and only between sketches (B6).
    private var canSwitch: Bool { model.macSupportsBlank && model.drawState == .live }

    var body: some View {
        PanelIconButton(systemImage: "display", emphasis: isBlank ? .plain : .selected) {
            storedSurface = CanvasSurface.mirror.rawValue
        }
        .disabled(!canSwitch)
        .accessibilityLabel("Mirror the Mac")
        .accessibilityAddTraits(isBlank ? [] : [.isSelected])

        // Picking Blank goes straight into Draw Mode, so it needs somewhere
        // for the sketch to go, exactly as Draw does.
        PanelIconButton(systemImage: "doc", emphasis: isBlank ? .selected : .plain) {
            storedSurface = CanvasSurface.blank.rawValue
        }
        .disabled(!canSwitch || !model.hasClaudeSession)
        .accessibilityLabel("Blank canvas")
        .accessibilityAddTraits(isBlank ? [.isSelected] : [])

        PanelDivider(vertical: vertical)

        // Disabled while there is no connection, on a Mac that is not running
        // Design Canvas, and while no Claude Code session is there to take the
        // sketch — the session list says which.
        PanelIconButton(systemImage: "pencil.and.outline", emphasis: .prominent, action: onDraw)
            .disabled(!model.canEnterDrawMode || !model.hasClaudeSession)
            .accessibilityLabel("Enter Draw Mode")
    }
}

/// In Draw Mode: undo and redo, pen and eraser, five inks, and the way to
/// throw the sketch away (M2, M6).
struct DrawTools: View {
    @ObservedObject var model: CanvasModel
    @ObservedObject var sketch: SketchCanvasController
    let vertical: Bool

    var body: some View {
        PanelIconButton(systemImage: "arrow.uturn.backward") { sketch.undo() }
            .disabled(sketch.strokeCount == 0)
            .accessibilityLabel("Undo the last stroke")
        PanelIconButton(systemImage: "arrow.uturn.forward") { sketch.redo() }
            .disabled(!sketch.canRedo)
            .accessibilityLabel("Redo")

        PanelDivider(vertical: vertical)

        PanelIconButton(systemImage: "pencil.tip", emphasis: sketch.tool == .pen ? .selected : .plain) {
            sketch.tool = .pen
        }
        .accessibilityLabel("Pen")
        .accessibilityAddTraits(sketch.tool == .pen ? [.isSelected] : [])
        PanelIconButton(systemImage: "eraser", emphasis: sketch.tool == .eraser ? .selected : .plain) {
            sketch.tool = .eraser
        }
        .accessibilityLabel("Eraser")
        .accessibilityAddTraits(sketch.tool == .eraser ? [.isSelected] : [])

        PanelDivider(vertical: vertical)

        ForEach(SketchColor.allCases) { swatch in
            Button {
                sketch.color = swatch
                sketch.tool = .pen
            } label: {
                Circle()
                    .fill(swatch.color)
                    .frame(width: 26, height: 26)
                    .padding(4)
                    .overlay(
                        Circle().strokeBorder(.primary, lineWidth: sketch.color == swatch ? 2 : 0)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(swatch.rawValue.capitalized) ink")
            .accessibilityAddTraits(sketch.color == swatch ? [.isSelected] : [])
        }

        PanelDivider(vertical: vertical)

        PanelIconButton(systemImage: "trash", tint: .canvasDangerText) { model.discard() }
            .accessibilityLabel("Leave Draw Mode and throw the sketch away")
    }
}
