// What says the picture has stopped (M1). While Draw Mode is open on the
// mirror, the iPad holds the frame it was showing when Draw was tapped, and the
// held picture looks exactly like a live one that happens not to move. So the
// hold is shown as a photograph (Figma v3.2, 2026-11-03): at the tap, the
// white flash of a camera, and the picture shrinks a little into a print whose
// paper fills the screen, the way a photo of the Mac's screen would sit on a
// white page. No words say it: the print does.
//
// The print itself is the zoom's (`ZoomModel.hold`): the picture rests
// smaller, the view around it is paper (`CanvasVideoHostView`, the sketch's
// bars), and the paper zooms with the picture, so it is never laid over it and
// never stays put on the screen while the picture moves. This view adds only
// the flash, and a hairline at the picture's edge so a white window on the
// Mac still stands apart from the paper. None of it is in the sketch: Send
// exports the ink alone. The blank page holds nothing, so it has none.

import SwiftUI
import UIKit

struct FrozenFrameIndicator: View {
    /// The picture is held: FREEZING or DRAWING, on the mirror.
    let active: Bool
    /// Where the picture is drawn right now, zoom and all.
    let picture: CGRect
    /// How much of the view around the picture is paper (`ZoomModel.paper`).
    let paper: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = 0.0

    var body: some View {
        ZStack {
            Color.white.opacity(flash)
            Rectangle()
                .path(in: picture)
                .stroke(Color.black.opacity(0.22 * paper), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if active { begin() } }
        .onChange(of: active) { active in
            if active { begin() } else { flash = 0 }
        }
    }

    private func begin() {
        UIAccessibility.post(notification: .announcement,
                             argument: "Picture frozen for drawing. Your Mac is still running.")
        guard !reduceMotion else { return }
        flash = 0.6
        withAnimation(.easeOut(duration: 0.4)) { flash = 0 }
    }
}
