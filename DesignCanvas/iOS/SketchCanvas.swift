// PencilKit, transparent, over the frozen frame.
//
// The canvas view is owned by the screen and not rebuilt per entry, because
// strokes have to survive leaving Draw Mode by cancel, rotation, link loss or
// a refused freeze and be there again on the next entry (M6, M7, PRD G6). Only
// an explicit clear — after a successful send, or Discard — empties it.
//
// The canvas fills the mirror layer and its strokes are stored in the
// coordinates of the unzoomed view. `ZoomModel` stays the one source of the
// zoom: the canvas is a scroll view that is only ever zoomed and scrolled from
// code, to match the video underneath, so ink stays on the part of the frame
// it was drawn on while the designer zooms in and out (technical_doc section
// 3, zoom in Draw Mode). Two fingers zoom and pan; one finger or the Pencil
// draws.
//
// Canvas setup and the transparent-PNG export follow ai.cst.2's
// `PencilCanvasView.swift`; its composite path is not used here (the Mac
// composites).

import PencilKit
import SwiftUI
import UIKit

/// The five review colours (M2). Named so the buttons can be labelled.
enum SketchColor: String, CaseIterable, Identifiable {
    case red, orange, blue, green, black

    var id: String { rawValue }

    var uiColor: UIColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .black: return .label
        }
    }

    var color: Color { Color(uiColor) }
}

enum SketchTool: String {
    case pen, eraser
}

/// Owns the `PKCanvasView` and everything the tool panel changes about it.
final class SketchCanvasController: NSObject, ObservableObject, PKCanvasViewDelegate {

    /// Strokes currently on the canvas — what enables Done (ruling 7).
    @Published private(set) var strokeCount = 0
    /// An undone stroke is there to bring back.
    @Published private(set) var canRedo = false
    @Published var tool: SketchTool = .pen { didSet { applyTool() } }
    @Published var color: SketchColor = .red { didSet { applyTool() } }

    let canvasView: PKCanvasView = {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Zoomed and scrolled from code only (`SketchCanvasHostView`): its own
        // pan and pinch would move the ink without moving the video.
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = CGFloat(ZoomModel.minScale)
        canvas.maximumZoomScale = CGFloat(ZoomModel.maxScale)
        canvas.pinchGestureRecognizer?.isEnabled = false
        // The mirror layer ignores the safe area; an inset here would shift
        // every stroke by it.
        canvas.contentInsetAdjustmentBehavior = .never
        // The ink must not depend on the iPad's appearance (M7). `.label` is
        // white in Dark Mode, so "black" would have exported as white strokes —
        // invisible over the light screenshot they are composited onto — and
        // the four dynamic system colours would each shift as well. Pinning the
        // canvas to the light appearance fixes every one of the five to what
        // its swatch shows.
        canvas.overrideUserInterfaceStyle = .light
        // Finger or pencil: an iPad without an Apple Pencil must still be able
        // to review (`.pencilOnly` is ai.cst.2's choice, not ours).
        canvas.drawingPolicy = .anyInput
        return canvas
    }()

    /// The part of the drawing Done sends, in the drawing's own coordinates:
    /// the whole picture, or the whole page. Kept current by the host view.
    fileprivate(set) var sketchRect = CGRect.zero

    override init() {
        super.init()
        canvasView.delegate = self
        applyTool()
    }

    func undo() {
        canvasView.undoManager?.undo()
        refreshRedo()
    }

    func redo() {
        canvasView.undoManager?.redo()
        refreshRedo()
    }

    private func refreshRedo() {
        let can = canvasView.undoManager?.canRedo ?? false
        if can != canRedo { canRedo = can }
    }

    /// Empty the canvas, and the undo stack with it: the strokes are gone for
    /// good once they have been sent or discarded.
    func clear() {
        canvasView.drawing = PKDrawing()
        canvasView.undoManager?.removeAllActions()
        strokeCount = 0
        canRedo = false
    }

    /// The sketch as a transparent PNG at the screen's native scale — the
    /// bytes the Mac flattens over its clean capture. It covers the whole
    /// picture whatever the zoom is (M5). Nil before the canvas has a size, or
    /// if it holds nothing.
    func sketchPNG() -> Data? {
        guard sketchRect.width > 1, sketchRect.height > 1, !canvasView.drawing.strokes.isEmpty else {
            return nil
        }
        let scale = canvasView.window?.screen.scale ?? UIScreen.main.scale
        return canvasView.drawing.image(from: sketchRect, scale: scale).pngData()
    }

    private func applyTool() {
        switch tool {
        case .pen:
            canvasView.tool = PKInkingTool(.pen, color: color.uiColor, width: 8)
        case .eraser:
            canvasView.tool = PKEraserTool(.bitmap)
        }
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let count = canvasView.drawing.strokes.count
        if count != strokeCount { strokeCount = count }
        refreshRedo()
    }
}

/// Hosts the controller's canvas view over the mirror. A fresh host is made on
/// every entry and takes the same canvas view in, so entering Draw Mode again
/// shows the same strokes.
struct SketchCanvas: UIViewRepresentable {
    @ObservedObject var controller: SketchCanvasController
    /// The mirror's zoom, shared with the video underneath.
    @Binding var zoom: ZoomModel
    /// `.zero` on the blank page, which has no picture and does not zoom.
    let videoSize: CGSize

    func makeUIView(context: Context) -> SketchCanvasHostView {
        let view = SketchCanvasHostView(controller: controller)
        view.videoSize = videoSize
        view.zoom = zoom

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.didPinch(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.didPan(_:)))
        // Two fingers always zoom (C2); one is a stroke and never reaches these.
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        for recognizer in [pinch, pan] as [UIGestureRecognizer] {
            // Fingers only: a resting hand next to the Pencil is not a pinch.
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.delegate = context.coordinator
            view.addGestureRecognizer(recognizer)
        }
        context.coordinator.host = view
        context.coordinator.recognizers = [pinch, pan]
        return view
    }

    func updateUIView(_ uiView: SketchCanvasHostView, context: Context) {
        context.coordinator.parent = self
        uiView.videoSize = videoSize
        uiView.zoom = zoom
    }

    static func dismantleUIView(_ uiView: SketchCanvasHostView, coordinator: Coordinator) {
        // The canvas outlives this host; do not leave it unable to draw.
        uiView.canvasView.drawingGestureRecognizer.isEnabled = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SketchCanvas
        weak var host: SketchCanvasHostView?
        var recognizers: [UIGestureRecognizer] = []

        init(_ parent: SketchCanvas) {
            self.parent = parent
        }

        @objc func didPinch(_ recognizer: UIPinchGestureRecognizer) {
            yieldDrawing()
            guard let host, recognizer.state == .changed else { return }
            // `scale` is cumulative since the gesture began; take it as a step
            // and reset, so the model only ever sees a factor.
            let factor = Double(recognizer.scale)
            recognizer.scale = 1
            parent.zoom.pinch(by: factor,
                              anchor: recognizer.location(in: host),
                              viewSize: host.bounds.size,
                              videoSize: parent.videoSize)
        }

        @objc func didPan(_ recognizer: UIPanGestureRecognizer) {
            yieldDrawing()
            guard let host, recognizer.state == .changed else { return }
            let translation = recognizer.translation(in: host)
            recognizer.setTranslation(.zero, in: host)
            parent.zoom.pan(by: CGSize(width: translation.x, height: translation.y),
                            viewSize: host.bounds.size,
                            videoSize: parent.videoSize)
        }

        /// The first finger of a pinch has already begun a stroke by the time
        /// the second lands. Turning the drawing recognizer off drops that
        /// stroke, and keeping it off until both gestures are over stops the
        /// moving fingers from starting another.
        private func yieldDrawing() {
            let zooming = recognizers.contains { $0.state == .began || $0.state == .changed }
            host?.canvasView.drawingGestureRecognizer.isEnabled = !zooming
        }

        // A pinch and a pan at once, and both alongside the stroke they are
        // about to cancel.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // The blank page has no picture to zoom.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            parent.videoSize != .zero
        }
    }
}

/// Keeps the canvas magnified and scrolled exactly as the video is, and covers
/// the letterbox bars so nothing can be drawn where there is no picture.
final class SketchCanvasHostView: UIView {

    let canvasView: PKCanvasView
    var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { setNeedsLayout() } } }
    var zoom = ZoomModel() { didSet { if zoom != oldValue { setNeedsLayout() } } }

    private let controller: SketchCanvasController
    /// Top, bottom, left, right. Opaque, so a stroke that runs off the picture
    /// is hidden, and plain views, so a touch on one starts no stroke.
    private let bars = (0..<4).map { _ in UIView() }
    /// The view size the canvas's content was last set to, at scale 1.
    private var contentBase = CGSize.zero

    init(controller: SketchCanvasController) {
        self.controller = controller
        canvasView = controller.canvasView
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        canvasView.drawingGestureRecognizer.isEnabled = true
        addSubview(canvasView)
        for bar in bars {
            bar.backgroundColor = .black
            addSubview(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        canvasView.frame = bounds
        controller.sketchRect = ZoomModel.sketchRect(videoSize: videoSize, in: size)

        // The content is the whole view at scale 1. The scroll view scales its
        // content size with the zoom itself, so that size is only ever set at
        // scale 1.
        if contentBase != size {
            canvasView.zoomScale = 1
            canvasView.contentSize = size
            contentBase = size
        }
        // No picture (the blank page): the page is the view and does not zoom.
        let zoom = videoSize == .zero ? ZoomModel() : self.zoom
        let scale = CGFloat(zoom.scale)
        if canvasView.zoomScale != scale { canvasView.zoomScale = scale }
        canvasView.contentOffset = zoom.sketchContentOffset(viewSize: size)
        // The scroll view turns its own pinch back on whenever its zoom range
        // changes hands; it must stay off, or it would zoom the ink alone.
        canvasView.pinchGestureRecognizer?.isEnabled = false

        let picture = videoSize == .zero
            ? bounds
            : zoom.transformedRect(viewSize: size, videoSize: videoSize).intersection(bounds)
        layoutBars(around: picture.isNull ? bounds : picture)
    }

    private func layoutBars(around picture: CGRect) {
        bars[0].frame = CGRect(x: 0, y: 0, width: bounds.width, height: picture.minY)
        bars[1].frame = CGRect(x: 0, y: picture.maxY,
                               width: bounds.width, height: bounds.height - picture.maxY)
        bars[2].frame = CGRect(x: 0, y: picture.minY, width: picture.minX, height: picture.height)
        bars[3].frame = CGRect(x: picture.maxX, y: picture.minY,
                               width: bounds.width - picture.maxX, height: picture.height)
    }
}
