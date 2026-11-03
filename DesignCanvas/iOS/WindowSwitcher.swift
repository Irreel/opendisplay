// What is on screen, under the session pill (Figma v3.1): the Mac's own screen
// or the whiteboard (B1). Tapping it opens the window menu (`MorphMenu`, M7):
// the icon travels into the row for what is on screen, and the chevron fades.
// The Mac's row is the Mac's own name, from its ping (PROTOCOL.md 11.3); a
// Mac that does not send one is "Your Mac".

import SwiftUI

struct WindowSwitcher: View {

    /// What is on screen.
    let surface: CanvasSurface
    /// The Mac's own name, when it sent one.
    var macName: String?
    /// The Mac can take a whiteboard sketch (B3).
    let whiteboardAvailable: Bool
    /// Not while a sketch is on its way (B6).
    let canSwitch: Bool
    var menuWidth: CGFloat = 340
    @Binding var isOpen: Bool
    let onPick: (CanvasSurface) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MorphMenu(isOpen: $isOpen, menuSize: CGSize(width: menuWidth, height: 400),
                  accessibilityLabel: "Window: \(title(surface))",
                  accessibilityHint: "Switches between your Mac's screen and the whiteboard") {
            label
        } menu: {
            VStack(alignment: .leading, spacing: 0) {
                row(.mirror)
                Divider()
                row(.blank)
            }
            .padding(.vertical, 10)
        } travellers: { frames in
            if travels, let from = frames[Part.buttonIcon], let to = frames[Part.rowIcon] {
                let at = isOpen ? to : from
                Self.icon(surface, size: 24)
                    .scaleEffect(isOpen ? to.width / from.width : 1, anchor: .leading)
                    .travelling(to: CGPoint(x: at.minX, y: at.midY))
            }
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Self.icon(surface, size: 24)
                .morphFrame(Part.buttonIcon)
                .opacity(travels ? 0 : 1)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.canvasSecondary)
                .frame(width: 14, height: 14)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(width: Self.width, height: 44)
    }

    private func row(_ option: CanvasSurface) -> some View {
        let isOn = option == surface
        return Button {
            onPick(option)
        } label: {
            HStack(spacing: 12) {
                Self.icon(option, size: 22)
                    .morphFrame(isOn ? Part.rowIcon : nil)
                    .opacity(travels && isOn ? 0 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(option))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if option == .mirror && isOn {
                            Circle()
                                .fill(Color.canvasSuccessMark)
                                .frame(width: 8, height: 8)
                        }
                        Text(detail(option))
                            .foregroundStyle(Color.canvasSecondary)
                    }
                    .font(.footnote)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isOn ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOn && !(canSwitch && (option == .mirror || whiteboardAvailable)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title(option)), \(detail(option))")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : [.isButton])
    }

    private func title(_ option: CanvasSurface) -> String {
        switch option {
        case .mirror: return macName ?? "Your Mac"
        case .blank: return "Whiteboard"
        }
    }

    private func detail(_ option: CanvasSurface) -> String {
        switch option {
        case .mirror:
            return option == surface ? "Live \u{00B7} mirrored here" : "The Mac\u{2019}s screen, live"
        case .blank:
            return whiteboardAvailable
                ? "A blank page, always ready to draw"
                : "Needs a newer Design Canvas on the Mac"
        }
    }

    /// The icon travels into the menu. With Reduce Motion it fades with the
    /// rest instead.
    private var travels: Bool { !reduceMotion }

    /// The button's width, for the top bar's layout.
    static let width: CGFloat = 60

    /// The display symbol for the Mac; the board's own glyph for the
    /// whiteboard, which has no system symbol.
    @ViewBuilder
    static func icon(_ surface: CanvasSurface, size: CGFloat) -> some View {
        switch surface {
        case .mirror:
            Image(systemName: "display")
                .font(.system(size: size * 0.75, weight: .medium))
                .frame(width: size, height: size)
        case .blank:
            Image("whiteboard")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }

    private enum Part {
        static let buttonIcon = "buttonIcon"
        static let rowIcon = "rowIcon"
    }
}
