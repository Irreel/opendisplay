// View-only zoom of the mirrored Mac display (PRD C2).
//
// The iPad never sends input, so this is pure presentation: the video is
// aspect-fitted in the view, then scaled about the pinch anchor and offset by
// the pan. The Mac is told nothing about it: a round is the whole frame
// whatever the zoom was (technical_doc section 3), so the zoom only has to be
// shared with the sketch surface, which is magnified with the video so that
// ink stays on the part of the frame it was drawn on.
//
// While the mirror is held (Draw Mode on the mirror, Figma v3.2) the picture
// is a print: it rests at 96% of its fit, centred, in paper that fills the
// view, and the paper is part of the photo. It zooms and pans with the
// picture, so the margin grows and goes off the screen like a real photo's
// border, instead of being laid over the picture.
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

    /// The print's resting scale while the picture is held; nil while it is
    /// live. Zooming out stops there, and a double tap goes back to it.
    private(set) var rest: Double?

    /// How much of the view around the picture is paper: 0 live, 1 held, in
    /// between only while the picture goes into its print or out of it.
    private(set) var paper = 0.0

    /// The held picture's size at rest, as a share of its fit: on an iPad in
    /// landscape, 24 points of paper at the sides and 59 at the top and
    /// bottom. At rest the paper is exactly the view.
    static let printScale = 0.96

    // MARK: - Gestures

    /// Multiply the scale by `factor`, keeping the video pixel under `anchor`
    /// (a point in view coordinates) under it.
    mutating func pinch(by factor: Double, anchor: CGPoint, viewSize: CGSize, videoSize: CGSize) {
        guard factor > 0, factor.isFinite else { return }
        let fitted = Self.fittedRect(videoSize: videoSize, in: viewSize)
        guard fitted.width > 0, fitted.height > 0 else { return }

        let newScale = min(max(scale * factor, rest ?? Self.minScale), Self.maxScale)
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

    /// Back to the fitted, centred picture, or, while it is held, to the
    /// print at rest.
    mutating func reset() {
        scale = rest ?? 1
        offset = .zero
    }

    // MARK: - The print

    /// Hold the picture as a print. At the fit it goes to the print's rest;
    /// zoomed in, it keeps its zoom, in the print's terms.
    mutating func hold(viewSize: CGSize, videoSize: CGSize) {
        rest = Self.printScale
        paper = 1
        scale *= Self.printScale
        offset = CGSize(width: offset.width * Self.printScale, height: offset.height * Self.printScale)
        clampOffset(fitted: Self.fittedRect(videoSize: videoSize, in: viewSize), viewSize: viewSize)
    }

    /// Let the print go: the live picture at the zoom the print was at, which
    /// at the print's rest is the fit.
    mutating func release(viewSize: CGSize, videoSize: CGSize) {
        let held = rest ?? 1
        rest = nil
        paper = 0
        scale = max(Self.minScale, scale / held)
        offset = CGSize(width: offset.width / held, height: offset.height / held)
        clampOffset(fitted: Self.fittedRect(videoSize: videoSize, in: viewSize), viewSize: viewSize)
    }

    /// `from` on the way to `to`, `progress` of the way: the picture going
    /// into its print or out of it. The rest is `to`'s throughout.
    static func blend(_ from: ZoomModel, _ to: ZoomModel, progress: Double) -> ZoomModel {
        var zoom = to
        let t = min(max(progress, 0), 1)
        zoom.scale = from.scale + (to.scale - from.scale) * t
        zoom.offset = CGSize(width: from.offset.width + (to.offset.width - from.offset.width) * t,
                             height: from.offset.height + (to.offset.height - from.offset.height) * t)
        zoom.paper = from.paper + (to.paper - from.paper) * t
        return zoom
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
    /// the part of the view it is able to cover. While it is held the same
    /// holds for the print, margin and all: the paper is the view at the
    /// print's rest, zoomed about the picture's centre, so panning stops at
    /// the paper's edge and the print at rest stays where it is.
    private mutating func clampOffset(fitted: CGRect, viewSize: CGSize) {
        let extent: CGSize
        if let rest {
            let zoom = CGFloat(scale / rest)
            extent = CGSize(width: viewSize.width * zoom, height: viewSize.height * zoom)
        } else {
            extent = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        }
        let slackX = max(0, (extent.width - viewSize.width) / 2)
        let slackY = max(0, (extent.height - viewSize.height) / 2)
        offset = CGSize(width: min(max(offset.width, -slackX), slackX),
                        height: min(max(offset.height, -slackY), slackY))
    }
}
