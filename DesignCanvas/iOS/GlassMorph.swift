// A control that opens into its own menu (Figma v3.1, M7 and M8, 2026-11-02):
// the control's glass grows from its top-left corner into the menu instead of
// a popover hanging under it, and the parts the two share (the session's name
// and dot, the window's icon) travel from the control into the menu's row for
// them, so the designer sees which row the control was. Everything else in the
// control fades as the glass starts to grow; the menu's rows fade in once it
// has nearly settled. A tap anywhere else (`CanvasScreen`) runs it backwards.
//
// The control holds its place in the row, open or not, so opening the menu
// moves nothing else on the screen. The glass, and the menu it becomes, are
// drawn behind it and out past it.

import SwiftUI
import UIKit

struct MorphMenu<Label: View, Menu: View, Travellers: View>: View {

    /// The menu is open. The screen holds it, to close the menu on a tap
    /// anywhere else.
    @Binding var isOpen: Bool
    /// The menu's width, and the most it may be tall.
    let menuSize: CGSize
    let accessibilityLabel: String
    let accessibilityHint: String
    @ViewBuilder let label: () -> Label
    @ViewBuilder let menu: () -> Menu
    /// The shared parts on their way, placed by the frames their two ends
    /// report with `morphFrame(_:)`. They stand in for both ends at rest as
    /// well, so nothing swaps when they land.
    @ViewBuilder let travellers: (_ frames: [String: CGRect]) -> Travellers

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    @State private var frames: [String: CGRect] = [:]

    static var space: String { "morphMenu" }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isOpen ? 28 : 22, style: .continuous)
    }

    var body: some View {
        Button {
            isOpen = true
        } label: {
            label()
                .contentShape(Capsule())
        }
        .buttonStyle(PressReporting(pressed: $pressed))
        .opacity(isOpen ? 0 : 1)
        // The control goes as the glass starts to grow, and comes back once
        // it is the control again.
        .animation(isOpen ? .easeOut(duration: 0.1) : .easeIn(duration: 0.1).delay(0.3), value: isOpen)
        .allowsHitTesting(!isOpen)
        .accessibilityHidden(isOpen)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .background(alignment: .topLeading) { glass }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(MorphFrames.self) { frames = $0 }
        .scaleEffect(pressed && !isOpen ? 0.96 : 1)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .onChange(of: isOpen) { open in
            guard open else { return }
            // Into the menu, which is modal while it is open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
        .onDisappear { isOpen = false }
    }

    /// One glass from control to menu: the control's size closed, the
    /// menu's open.
    private var glass: some View {
        let open = frames[MorphFrames.menu]?.size
        return ZStack(alignment: .topLeading) {
            // The menu at its full size from the start, so the rows are where
            // the shared parts are going; the glass reveals it.
            Color.clear
                .frame(width: menuSize.width, height: menuSize.height)
                .overlay(alignment: .topLeading) {
                    menu()
                        .frame(width: menuSize.width)
                        .morphFrame(MorphFrames.menu)
                        .opacity(isOpen ? 1 : 0)
                        .offset(y: isOpen ? 0 : -6)
                        .animation(isOpen ? .easeOut(duration: 0.2).delay(0.19) : .easeOut(duration: 0.1),
                                   value: isOpen)
                        .allowsHitTesting(isOpen)
                        .accessibilityHidden(!isOpen)
                }
        }
        // Closed, the size the control is given; open, the menu's.
        .frame(minWidth: isOpen ? open?.width : 0, maxWidth: isOpen ? open?.width : .infinity,
               minHeight: isOpen ? open?.height : 0, maxHeight: isOpen ? open?.height : .infinity,
               alignment: .topLeading)
        .clipShape(shape)
        .canvasGlass(in: shape)
        .overlay(alignment: .topLeading) { travellers(frames) }
        .animation(morph, value: isOpen)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isOpen ? .isModal : [])
        .accessibilityAction(.escape) { isOpen = false }
    }

    /// Open on a spring with a little give; closed on a plain ease, once
    /// the rows have gone. With Reduce Motion, a short ease either way.
    private var morph: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return isOpen
            ? .spring(response: 0.4, dampingFraction: 0.85)
            : .easeInOut(duration: 0.35).delay(0.05)
    }
}

/// Where the parts of a morph are laid out, in `MorphMenu.space`.
struct MorphFrames: PreferenceKey {
    static let menu = "menu"
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports where this view is laid out to the `MorphMenu` around it, as
    /// `part`; nothing for `nil`.
    func morphFrame(_ part: String?) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: MorphFrames.self,
                                   value: part.map { [$0: geo.frame(in: .named("morphMenu"))] } ?? [:])
        })
    }

    /// Places a traveller of the morph: its leading edge and vertical centre
    /// at `point`, in the `MorphMenu`'s space.
    func travelling(to point: CGPoint) -> some View {
        frame(width: 0, height: 0, alignment: .leading)
            .offset(x: point.x, y: point.y)
            .accessibilityHidden(true)
    }
}

/// A plain button that says when it is held, so the whole control, glass and
/// all, can press in.
struct PressReporting: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed = $0 }
    }
}
