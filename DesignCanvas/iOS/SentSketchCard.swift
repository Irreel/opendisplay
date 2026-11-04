// What says the sketch has gone (M5). Done sends the ink alone, which the Mac
// lays over its own copy of the frozen frame, but what the designer is sending
// is the picture they drew on, so that is what is seen leaving. At the tap the
// picture and its ink, as they are on the screen and without the chrome, flash
// like a camera, lift off as a print in the frozen frame's white border, and
// fly into the session pill, where the sketch went (Figma v3.1, S), the way
// a screenshot shrinks into its thumbnail. The border grows outward as the card lifts, so it never covers
// ink at the picture's edge. The live picture is already back underneath.
//
// The card is a snapshot of the mirror layer's own views (`MirrorViews`), cut
// to where the picture is, so it starts exactly over what it shows. It takes
// no touches and is gone in under a second. With Reduce Motion it only fades.

import SwiftUI
import UIKit

/// The mirror layer's views, held so Send can take a picture of the screen
/// with none of the chrome over it.
final class MirrorViews {
    weak var video: UIView?

    /// The picture and its ink inside `rect`, as they are on the screen now.
    /// `ink` is the sketch's host view. `rect` is in the mirror layer's
    /// coordinates, which both views fill.
    func snapshot(of rect: CGRect, blank: Bool, ink: UIView?) -> UIView? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let picture = UIView(frame: CGRect(origin: .zero, size: rect.size))
        picture.backgroundColor = blank ? .white : .black
        let sources: [UIView?] = blank ? [ink] : [video, ink]
        for case let source? in sources {
            guard let still = source.resizableSnapshotView(from: rect, afterScreenUpdates: false,
                                                           withCapInsets: .zero) else { continue }
            still.frame = picture.bounds
            still.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            picture.addSubview(still)
        }
        return picture
    }
}

/// One sketch on its way out.
struct SentSketch: Identifiable {
    let id = UUID()
    let picture: UIView
    /// Where the picture was on the screen, in the mirror layer's coordinates.
    let rect: CGRect
    /// Drawn on the frozen mirror, so the card is a print in the frozen
    /// frame's border. The blank page had no frame.
    let frozen: Bool
}

/// Where the card goes: the session pill, in global coordinates.
struct SendTargetKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// The session pill takes the card in: it swells a little and settles.
struct LandingPulse: ViewModifier {
    let landings: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swelled = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(swelled ? 1.08 : 1)
            .onChange(of: landings) { _ in
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { swelled = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { swelled = false }
                }
            }
    }
}

struct SentSketchCard: View {
    let sketch: SentSketch
    /// The session pill, once it is laid out.
    let target: CGRect?
    let onLanded: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = 0.0
    @State private var lifted = false
    /// How far the print's border has grown out from the picture, 0 to 1.
    @State private var printed: CGFloat = 0
    @State private var scale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var opacity = 1.0
    /// `target` as it is when the card sets off, kept current as the top
    /// bar settles after Draw Mode.
    @State private var latestTarget: CGRect?

    private var shape: RoundedRectangle {
        // A print's corners are barely rounded.
        RoundedRectangle(cornerRadius: lifted ? (sketch.frozen ? 6 : 28) : 0, style: .continuous)
    }

    /// The print's border, as shares of the picture's width: even on three
    /// sides and deeper at the bottom, as on a Polaroid.
    private static let borderSide: CGFloat = 0.02
    private static let borderBottom: CGFloat = 0.0667

    private var border: EdgeInsets {
        let side = sketch.rect.width * Self.borderSide * printed
        let bottom = sketch.rect.width * Self.borderBottom * printed
        return EdgeInsets(top: side, leading: side, bottom: bottom, trailing: side)
    }

    var body: some View {
        GeometryReader { geo in
            SnapshotHost(view: sketch.picture)
                .overlay(Color.white.opacity(flash))
                .frame(width: sketch.rect.width, height: sketch.rect.height)
                .overlay {
                    if sketch.frozen {
                        Rectangle().stroke(Color.black.opacity(0.22 * printed), lineWidth: 1)
                    }
                }
                .padding(border)
                .background(sketch.frozen ? Color.canvasPhotoPaper : Color.black)
                .clipShape(shape)
                .overlay {
                    if !sketch.frozen {
                        shape.strokeBorder(Color(.separator), lineWidth: 1)
                    }
                }
                .background(shape.fill(Color.black)
                    .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 30, y: 12))
                // One layer, so it fades as a card and not as a snapshot over
                // the black it is backed with.
                .compositingGroup()
                .scaleEffect(scale)
                .offset(offset)
                .opacity(opacity)
                .position(x: sketch.rect.midX, y: sketch.rect.midY)
                .onAppear { play(in: geo.frame(in: .global)) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { latestTarget = target }
        .onChange(of: target) { latestTarget = $0 }
    }

    /// Flash and lift, then fly into the pill. `screen` is this view's frame
    /// in global coordinates.
    private func play(in screen: CGRect) {
        UIAccessibility.post(notification: .announcement, argument: "Sending sketch")
        guard !reduceMotion else {
            withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
            after(0.3, onLanded)
            return
        }
        flash = 0.5
        withAnimation(.easeOut(duration: 0.3)) { flash = 0 }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            lifted = true
            printed = sketch.frozen ? 1 : 0
            scale = 0.62
        }
        let center = CGPoint(x: screen.minX + sketch.rect.midX, y: screen.minY + sketch.rect.midY)
        // Where the pill is, should it not be laid out by then.
        let fallback = CGRect(x: screen.minX + 16, y: screen.minY + 16, width: 44, height: 44)
        // It shrinks early and speeds up on its way, so it is small by the
        // time it reaches the pill, and only fades as it goes in.
        after(0.45) {
            let to = latestTarget ?? fallback
            withAnimation(.easeInOut(duration: 0.38)) {
                scale = max(to.width, 24) / sketch.rect.width
            }
            withAnimation(.easeIn(duration: 0.38)) {
                offset = CGSize(width: to.midX - center.x, height: to.midY - center.y)
            }
            withAnimation(.linear(duration: 0.08).delay(0.3)) { opacity = 0 }
        }
        after(0.83, onLanded)
    }

    private func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Puts the snapshot, a plain UIKit view, in the card.
private struct SnapshotHost: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(view)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
