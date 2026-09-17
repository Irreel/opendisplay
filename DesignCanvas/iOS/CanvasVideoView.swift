// The mirror itself: a UIView whose only job is to host the receiver's
// `AVSampleBufferDisplayLayer` at the rect `ZoomModel` says it belongs in, and
// to turn pinch, pan and double-tap into changes to that model.
//
// A deliberately simpler sibling of OpenDisplay's `VideoLayerView`: no touch
// forwarding, no cursor, no Metal path (plan ruling 9). The iPad is
// view-and-draw only, so nothing here ever reaches the Mac.

import AVFoundation
import SwiftUI
import UIKit

struct CanvasVideoView: UIViewRepresentable {

    let displayLayer: AVSampleBufferDisplayLayer
    let videoSize: CGSize
    @Binding var zoom: ZoomModel

    func makeUIView(context: Context) -> CanvasVideoHostView {
        let view = CanvasVideoHostView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.isMultipleTouchEnabled = true
        view.videoSize = videoSize
        view.zoom = zoom
        view.layer.addSublayer(displayLayer)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.didPinch(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.didPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.didDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        // Zooming with two fingers is a pinch and a pan at once.
        pinch.delegate = context.coordinator
        pan.delegate = context.coordinator
        for recognizer in [pinch, pan, doubleTap] as [UIGestureRecognizer] {
            view.addGestureRecognizer(recognizer)
        }
        context.coordinator.host = view
        return view
    }

    func updateUIView(_ uiView: CanvasVideoHostView, context: Context) {
        context.coordinator.parent = self
        uiView.videoSize = videoSize
        uiView.zoom = zoom
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CanvasVideoView
        weak var host: CanvasVideoHostView?

        init(_ parent: CanvasVideoView) {
            self.parent = parent
        }

        @objc func didPinch(_ recognizer: UIPinchGestureRecognizer) {
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
            guard let host, recognizer.state == .changed else { return }
            let translation = recognizer.translation(in: host)
            recognizer.setTranslation(.zero, in: host)
            parent.zoom.pan(by: CGSize(width: translation.x, height: translation.y),
                            viewSize: host.bounds.size,
                            videoSize: parent.videoSize)
        }

        @objc func didDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !parent.zoom.isLocked else { return }
            parent.zoom.reset()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Lays the display layer out where the zoom says the picture is.
final class CanvasVideoHostView: UIView {

    var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { setNeedsLayout() } } }
    var zoom = ZoomModel() { didSet { if zoom != oldValue { setNeedsLayout() } } }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layer = layer.sublayers?.first else { return }
        // No implicit animation: the picture must track the fingers, and a
        // rotation must not slide the layer across the screen.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The transformed rect already carries the video's aspect ratio, so
        // the layer's own `resizeAspect` fills it exactly; if the video size
        // is not known yet, the full bounds keep the letterboxing sane.
        if videoSize == .zero {
            layer.frame = bounds
        } else {
            layer.frame = zoom.transformedRect(viewSize: bounds.size, videoSize: videoSize)
        }
        CATransaction.commit()
    }
}
