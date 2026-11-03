// The tool panel (Figma v3.1): the drawing tools, out only while drawing, at
// the bottom centre until the designer drags it to another edge
// (`PanelEdge`); on a side edge its controls run top to bottom. It drags from
// anywhere; its grabber shows only while it is being moved, and for a moment
// when the panel first appears, inside the panel on the side that faces into
// the screen.
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
            .frame(width: vertical ? 24 : 1, height: vertical ? 1 : 24)
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
        RoundedRectangle(cornerRadius: 28, style: .continuous)
    }

    /// The grabber is feedback, not a precondition: the panel drags from
    /// anywhere, and the grabber shows only while it is being moved.
    private var showsHandle: Bool { drag != .zero || hinting }

    var body: some View {
        let vertical = edge.isVertical
        let controls = vertical
            ? AnyLayout(VStackLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: 2))
        controls { content(vertical) }
        .padding(6)
        .canvasGlass(in: Self.shape)
        // The grabber sits inside the panel, in its margin, on the side that
        // faces into the screen: along the top of a row docked at the bottom,
        // the right of a column on the left. The panel does not grow for it.
        .overlay(alignment: edge.opposite.alignment) {
            if showsHandle {
                handle(vertical: vertical)
                    .padding(Edge.Set(edge.opposite.transitionEdge), Self.handleInset)
                    .transition(.opacity)
            }
        }
        .contentShape(Self.shape)
        .overlay(alignment: .top) { positionControl }
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

    /// How far the grabber sits in from the panel's side, inside its 6-point
    /// margin.
    private static var handleInset: CGFloat { 3 }

    private func handle(vertical: Bool) -> some View {
        Capsule()
            .fill(Color.canvasSecondary)
            .frame(width: vertical ? 4 : 30, height: vertical ? 30 : 4)
            .allowsHitTesting(false)
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

    /// The screen edge the panel comes in from and goes out by.
    var transitionEdge: Edge {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

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

/// While drawing: undo and redo, pen and eraser, five inks, and Clear all.
/// Where the screen is too short along the panel for all five inks, as on an
/// iPhone, one swatch stands for them and offers the five when tapped.
struct DrawTools: View {
    @ObservedObject var sketch: SketchCanvasController
    let vertical: Bool
    var compact = false
    /// The Ink Picker is open, on a compact panel.
    var inkPickerOpen: Binding<Bool> = .constant(false)

    /// The panel's length along its row: five 44-point buttons, five 38-point
    /// swatches and three dividers, with 2-point gaps and 6-point padding —
    /// or one swatch in place of five.
    static func length(compact: Bool) -> CGFloat { compact ? 289 : 449 }
    /// The panel across its row.
    static let thickness: CGFloat = 56

    var body: some View {
        PanelIconButton(systemImage: "arrow.uturn.backward", size: 44) { sketch.undo() }
            .disabled(sketch.strokeCount == 0)
            .accessibilityLabel("Undo the last stroke")
        PanelIconButton(systemImage: "arrow.uturn.forward", size: 44) { sketch.redo() }
            .disabled(!sketch.canRedo)
            .accessibilityLabel("Redo")

        PanelDivider(vertical: vertical)

        PanelIconButton(systemImage: "pencil.tip", emphasis: sketch.tool == .pen ? .selected : .plain,
                        size: 44) {
            sketch.tool = .pen
        }
        .accessibilityLabel("Pen")
        .accessibilityAddTraits(sketch.tool == .pen ? [.isSelected] : [])
        PanelIconButton(systemImage: "eraser", emphasis: sketch.tool == .eraser ? .selected : .plain,
                        size: 44) {
            sketch.tool = .eraser
        }
        .accessibilityLabel("Eraser")
        .accessibilityAddTraits(sketch.tool == .eraser ? [.isSelected] : [])

        PanelDivider(vertical: vertical)

        if compact {
            InkPicker(sketch: sketch, isOpen: inkPickerOpen)
        } else {
            InkSwatches(sketch: sketch)
        }

        PanelDivider(vertical: vertical)

        // The page, not the sketch: drawing goes on, and Undo brings the
        // strokes back. Ending without sending is End drawing's.
        PanelIconButton(systemImage: "trash", tint: .canvasDangerText, size: 44) { sketch.eraseAll() }
            .disabled(sketch.strokeCount == 0)
            .accessibilityLabel("Clear all")
    }
}

/// The five inks, the current one ringed. Picking one also picks the pen.
private struct InkSwatches: View {
    @ObservedObject var sketch: SketchCanvasController
    var onPick: () -> Void = {}

    var body: some View {
        ForEach(SketchColor.allCases) { swatch in
            Button {
                sketch.color = swatch
                sketch.tool = .pen
                onPick()
            } label: {
                InkDot(color: swatch.color, ringed: sketch.color == swatch)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(swatch.rawValue.capitalized) ink")
            .accessibilityAddTraits(sketch.color == swatch ? [.isSelected] : [])
        }
    }
}

/// One swatch for the five, on a screen too short for them all. It opens the
/// Ink Picker (`InkPickerCapsule`), which the screen lays over everything
/// beside the panel; this reports where the swatch is so it can.
private struct InkPicker: View {
    @ObservedObject var sketch: SketchCanvasController
    @Binding var isOpen: Bool

    var body: some View {
        Button { isOpen.toggle() } label: {
            InkDot(color: sketch.color.color, ringed: isOpen)
        }
        .buttonStyle(.plain)
        .background(GeometryReader { geo in
            Color.clear.preference(key: InkSwatchFrameKey.self, value: geo.frame(in: .named("chrome")))
        })
        .accessibilityLabel("Ink")
        .accessibilityValue(sketch.color.rawValue.capitalized)
        .accessibilityHint("Shows the five inks")
    }
}

/// Where the compact panel's swatch is, in the chrome's space.
struct InkSwatchFrameKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// The Ink Picker (Figma v3.1, iPhone 02d): the five inks on their own glass,
/// next to the compact panel's swatch, the current one ringed. Picking one
/// also picks the pen and closes it.
struct InkPickerCapsule: View {
    @ObservedObject var sketch: SketchCanvasController
    let vertical: Bool
    let onPick: () -> Void

    /// Its length: five 38-point swatches, 2-point gaps, 6-point padding.
    static let length: CGFloat = 5 * 38 + 4 * 2 + 12

    var body: some View {
        let row = vertical
            ? AnyLayout(VStackLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: 2))
        row {
            InkSwatches(sketch: sketch, onPick: onPick)
        }
        .padding(6)
        .canvasGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct InkDot: View {
    let color: Color
    let ringed: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 26, height: 26)
            .padding(3)
            .overlay(Circle().strokeBorder(.primary, lineWidth: ringed ? 2 : 0))
            .frame(width: 38, height: 44)
            .contentShape(Rectangle())
    }
}
