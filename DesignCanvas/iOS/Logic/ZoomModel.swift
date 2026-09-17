// View-only zoom of the mirrored Mac display (PRD C2).
//
// The iPad never sends input, so this is pure presentation: the video is
// aspect-fitted in the view, then scaled about the pinch anchor and offset by
// the pan. What the Mac needs to know about it is one number set — the part of
// the video that is on screen, normalised — which rides the `freeze` and
// `annotation` messages as `zoomRect` so the Mac crops the clean frame to the
// same region the user drew on.
//
// Foundation + CoreGraphics only: this file is compiled into the hostless test
// bundle as well as the app (see project.yml).

import CoreGraphics
import Foundation

struct ZoomModel: Equatable {

    /// Fitted size. Zooming out past the fit would only add empty space.
    static let minScale = 1.0
    /// Six was the ceiling in ai.cst.2's review canvas and is about the point
    /// where an iPad pixel stops standing for anything on the Mac's screen.
    static let maxScale = 6.0

    private(set) var scale = 1.0

    /// Points, relative to the fitted video's centre. Positive moves the
    /// picture right and down, which reveals its top-left.
    private(set) var offset = CGSize.zero

    /// True in Draw Mode: the sketch is pinned to the frame it was started on,
    /// so gestures are ignored until it ends (technical_doc section 3).
    var isLocked = false

    // MARK: - Gestures

    /// Multiply the scale by `factor`, keeping the video pixel under `anchor`
    /// (a point in view coordinates) under it.
    mutating func pinch(by factor: Double, anchor: CGPoint, viewSize: CGSize, videoSize: CGSize) {
        guard !isLocked, factor > 0, factor.isFinite else { return }
        let fitted = Self.fittedRect(videoSize: videoSize, in: viewSize)
        guard fitted.width > 0, fitted.height > 0 else { return }

        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        guard newScale != scale else { return }

        // Where the anchor sits in the video, as a fraction of it, before the
        // change; solving for the offset that keeps it there after.
        let before = transformedRect(fitted: fitted)
        let u = (anchor.x - before.minX) / before.width
        let v = (anchor.y - before.minY) / before.height

        scale = newScale
        let width = fitted.width * scale
        let height = fitted.height * scale
        offset = CGSize(width: anchor.x - u * width + width / 2 - fitted.midX,
                        height: anchor.y - v * height + height / 2 - fitted.midY)
        clampOffset(fitted: fitted, viewSize: viewSize)
    }

    /// Drag the picture by `delta` points, clamped so it never uncovers part of
    /// the view it could have covered.
    mutating func pan(by delta: CGSize, viewSize: CGSize, videoSize: CGSize) {
        guard !isLocked else { return }
        let fitted = Self.fittedRect(videoSize: videoSize, in: viewSize)
        guard fitted.width > 0, fitted.height > 0 else { return }
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        clampOffset(fitted: fitted, viewSize: viewSize)
    }

    /// Back to the fitted, centred picture. The lock is not a zoom property and
    /// is left alone.
    mutating func reset() {
        scale = 1
        offset = .zero
    }

    // MARK: - Geometry

    /// The video aspect-fitted and centred in the view, at scale 1.
    static func fittedRect(videoSize: CGSize, in viewSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let fit = min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        let size = CGSize(width: videoSize.width * fit, height: videoSize.height * fit)
        return CGRect(x: (viewSize.width - size.width) / 2,
                      y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Where the video is drawn in the view right now: the fitted rect scaled
    /// about its own centre and moved by the offset.
    func transformedRect(viewSize: CGSize, videoSize: CGSize) -> CGRect {
        transformedRect(fitted: Self.fittedRect(videoSize: videoSize, in: viewSize))
    }

    /// The part of the video the view shows, normalised to the video with a
    /// top-left origin — `.full` whenever the whole picture is on screen.
    func visibleRect(viewSize: CGSize, videoSize: CGSize) -> NormalizedRect {
        let drawn = transformedRect(viewSize: viewSize, videoSize: videoSize)
        guard drawn.width > 0, drawn.height > 0 else { return .full }
        let view = CGRect(origin: .zero, size: viewSize)
        let shown = drawn.intersection(view)
        guard !shown.isNull, shown.width > 0, shown.height > 0 else { return .full }
        return NormalizedRect(x: Double((shown.minX - drawn.minX) / drawn.width),
                              y: Double((shown.minY - drawn.minY) / drawn.height),
                              width: Double(shown.width / drawn.width),
                              height: Double(shown.height / drawn.height))
    }

    // MARK: - Private

    private func transformedRect(fitted: CGRect) -> CGRect {
        let width = fitted.width * scale
        let height = fitted.height * scale
        let centre = CGPoint(x: fitted.midX + offset.width, y: fitted.midY + offset.height)
        return CGRect(x: centre.x - width / 2, y: centre.y - height / 2,
                      width: width, height: height)
    }

    /// On an axis where the picture is larger than the view, hold its edges
    /// outside the view; on one where it is smaller (the letterbox bars at low
    /// zoom), keep it centred. Either way the user cannot drag the picture off
    /// the part of the view it is able to cover.
    private mutating func clampOffset(fitted: CGRect, viewSize: CGSize) {
        let slackX = max(0, (fitted.width * scale - viewSize.width) / 2)
        let slackY = max(0, (fitted.height * scale - viewSize.height) / 2)
        offset = CGSize(width: min(max(offset.width, -slackX), slackX),
                        height: min(max(offset.height, -slackY), slackY))
    }
}
