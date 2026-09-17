// PencilKit, transparent, over the frozen frame.
//
// The canvas view is owned by the screen and not rebuilt per entry, because
// strokes have to survive leaving Draw Mode by cancel, rotation, link loss or
// a refused freeze and be there again on the next entry (M6, M7, PRD G6). Only
// an explicit clear — after a successful send, or Discard — empties it.
//
// Canvas setup and the transparent-PNG export follow ai.cst.2's
// `PencilCanvasView.swift`; its composite path and scroll-view zoom are not
// used here (the Mac composites, and zoom is the mirror's own).

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
    @Published var tool: SketchTool = .pen { didSet { applyTool() } }
    @Published var color: SketchColor = .red { didSet { applyTool() } }

    let canvasView: PKCanvasView = {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        // Finger or pencil: an iPad without an Apple Pencil must still be able
        // to review (`.pencilOnly` is ai.cst.2's choice, not ours).
        canvas.drawingPolicy = .anyInput
        return canvas
    }()

    override init() {
        super.init()
        canvasView.delegate = self
        applyTool()
    }

    func undo() { canvasView.undoManager?.undo() }

    /// Empty the canvas, and the undo stack with it: the strokes are gone for
    /// good once they have been sent or discarded.
    func clear() {
        canvasView.drawing = PKDrawing()
        canvasView.undoManager?.removeAllActions()
        strokeCount = 0
    }

    /// The sketch as a transparent PNG at the screen's native scale — the
    /// bytes the Mac flattens over its clean capture. Nil before the canvas
    /// has a size, or if it holds nothing.
    func sketchPNG() -> Data? {
        let bounds = canvasView.bounds
        guard bounds.width > 1, bounds.height > 1, !canvasView.drawing.strokes.isEmpty else {
            return nil
        }
        let scale = canvasView.window?.screen.scale ?? UIScreen.main.scale
        return canvasView.drawing.image(from: bounds, scale: scale).pngData()
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
    }
}

/// Hosts the controller's canvas view. `makeUIView` hands back the object the
/// controller owns, so entering Draw Mode again shows the same strokes.
struct SketchCanvas: UIViewRepresentable {
    @ObservedObject var controller: SketchCanvasController

    func makeUIView(context: Context) -> PKCanvasView {
        controller.canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}
