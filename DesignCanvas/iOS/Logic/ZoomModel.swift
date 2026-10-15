// View-only zoom of the mirrored Mac display (PRD C2).
//
// The iPad never sends input, so this is pure presentation: the video is
// aspect-fitted in the view, then scaled about the pinch anchor and offset by
// the pan. The Mac is told nothing about it: a round is the whole frame
// whatever the zoom was (technical_doc section 3), so the zoom only has to be
// shared with the sketch surface, which is magnified with the video so that
// ink stays on the part of the frame it was drawn on.
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

    // MARK: - Gestures

    /// Multiply the scale by `factor`, keeping the video pixel under `anchor`
    /// (a point in view coordinates) under it.
    mutating func pinch(by factor: Double, anchor: CGPoint, viewSize: CGSize, videoSize: CGSize) {
        guard factor > 0, factor.isFinite else { return }
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
        let fitted = Self.fittedRect(videoSize: videoSize, in: viewSize)
        guard fitted.width > 0, fitted.height > 0 else { return }
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        clampOffset(fitted: fitted, viewSize: viewSize)
    }

    /// Back to the fitted, centred picture.
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

    /// The part of the unzoomed view a sketch is sent for: the whole picture,
    /// or the whole view when there is no picture (the blank page). It is what
    /// Done exports and what `viewport` reports.
    static func sketchRect(videoSize: CGSize, in viewSize: CGSize) -> CGRect {
        let fitted = fittedRect(videoSize: videoSize, in: viewSize)
        return fitted.isEmpty ? CGRect(origin: .zero, size: viewSize) : fitted
    }

    /// Where the sketch's scroll view has to be scrolled to. Its content is
    /// the whole view as it is at scale 1, magnified by `scale`, so a stroke
    /// stored at an unzoomed point lands on the video pixel it was drawn on.
    /// Always inside the scroll range: the clamp never lets the picture
    /// uncover more of the view than the fit already does.
    func sketchContentOffset(viewSize: CGSize) -> CGPoint {
        CGPoint(x: viewSize.width / 2 * (scale - 1) - offset.width,
                y: viewSize.height / 2 * (scale - 1) - offset.height)
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
