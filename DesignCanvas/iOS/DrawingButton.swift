// The one way in and out of drawing on the mirror (Figma v3.1), at the bottom
// left: a round glass button with no words, as the system's tool picker is
// when it is tucked away. The pencil holds the mirror as a print and brings
// out the tool panel; the cross lets the print go and the mirror is live
// again. A sketch that has not been sent is not kept, so with ink on the page
// the cross asks first ("End without sending?", grown from the button); with
// none it ends at once. The whiteboard has nothing to hold, so it has no
// button: it is always ready to draw.

import SwiftUI

struct DrawingButton: View {
    enum Action { case start, end }

    let action: Action
    /// Off while the tool panel divides from it (`DividingCell`), whose
    /// outline is its glass then.
    var glass = true
    let onTap: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // One glass for both: only the symbol changes.
                Image(systemName: action == .start ? "pencil.tip" : "xmark")
                    .font(.system(size: action == .start ? 24 : 20, weight: .medium))
                    .id(action)
                    .transition(.opacity)
            }
            .foregroundStyle(Color.primary)
            .frame(width: Self.size, height: Self.size)
            .glass(glass)
            .contentShape(Circle())
        }
        // It gives a little under the finger (M1).
        .buttonStyle(GivesUnderFinger())
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(action == .start ? "Start drawing" : "End drawing")
        .accessibilityHint(action == .start
                           ? "Holds the picture so you can draw on it"
                           : "Lets the picture go live again")
    }

    /// Its width and height: a 56-point circle, the tool panel's thickness.
    static let size: CGFloat = 56
}

private extension View {
    @ViewBuilder func glass(_ on: Bool) -> some View {
        if on { canvasGlass(in: Circle()) } else { self }
    }
}

/// Presses in to 96% while held.
struct GivesUnderFinger: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension AnyTransition {
    /// How a menu or a question opens from its control and goes again (M5):
    /// in from 90% with its corner pinned, out to 96% in 0.2 s, fading both
    /// ways.
    static func popOut(from anchor: UnitPoint) -> AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.9, anchor: anchor).combined(with: .opacity),
                    removal: .scale(scale: 0.96, anchor: anchor).combined(with: .opacity)
                        .animation(.easeOut(duration: 0.2)))
    }
}

/// "End without sending?": grown from End drawing, pinned to its leading
/// edge. No Cancel row: a tap anywhere else keeps drawing (`CanvasScreen`).
struct EndConfirmation: View {
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("End without sending?")
                    .font(.subheadline.weight(.semibold))
                Text("Your sketch won\u{2019}t be saved.")
                    .font(.footnote)
                    .foregroundStyle(Color.canvasSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            Button(action: onEnd) {
                HStack {
                    Text("End without sending")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "trash")
                        .font(.system(size: 17))
                }
                .foregroundStyle(Color.canvasDangerText)
                .padding(.leading, 20)
                .padding(.trailing, 16)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .canvasGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
