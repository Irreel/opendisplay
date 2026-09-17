// Draw Mode's tool panel: pen, eraser, undo, five colours, the optional note,
// and the three ways out (M2, M4, M5, M6).
//
// The sketch surface itself is placed by `CanvasScreen`, over the part of the
// view the video actually covers — the Mac stretches the sketch over the crop
// it makes from `zoomRect`, so the two rects have to be the same rect. This
// panel sits in the screen's safe-area chrome instead, clear of it.
//
// The overlay owns no Draw Mode logic — every button feeds `CanvasModel`,
// which runs the state machine and performs its effects. Done is disabled
// until the Mac has confirmed the freeze and there is at least one stroke
// (ruling 7), which is exactly `model.canSend`.

import SwiftUI

struct DrawModeOverlay: View {

    @ObservedObject var model: CanvasModel
    @ObservedObject var sketch: SketchCanvasController

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                toolButton(.pen, systemImage: "pencil.tip", label: "Pen")
                toolButton(.eraser, systemImage: "eraser", label: "Eraser")

                Button {
                    sketch.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .disabled(sketch.strokeCount == 0)
                .accessibilityLabel("Undo the last stroke")

                Divider().frame(height: 28)

                ForEach(SketchColor.allCases) { swatch in
                    Button {
                        sketch.color = swatch
                        sketch.tool = .pen
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle()
                                    .strokeBorder(.primary,
                                                  lineWidth: sketch.color == swatch ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(swatch.rawValue.capitalized) ink")
                    .accessibilityAddTraits(sketch.color == swatch ? [.isSelected] : [])
                }
            }

            // M4: one line, optional. Empty means no note is sent at all.
            TextField("Add a note for Claude Code (optional)", text: $model.note)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .frame(maxWidth: 520)

            HStack(spacing: 12) {
                // M6: leaves Draw Mode, keeps the strokes for the next entry.
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Leave Draw Mode and keep the sketch")

                Button("Discard", role: .destructive) { model.discard() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Leave Draw Mode and throw the sketch away")

                Spacer(minLength: 0)

                Button {
                    guard let png = sketch.sketchPNG() else { return }
                    model.done(sketchPNG: png)
                } label: {
                    Label("Done", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
                .accessibilityLabel("Send the sketch to Claude Code")
            }
            .frame(maxWidth: 520)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 12, y: 4)
        .padding(.horizontal, 16)
    }

    private func toolButton(_ tool: SketchTool, systemImage: String, label: String) -> some View {
        Button {
            sketch.tool = tool
        } label: {
            Image(systemName: systemImage)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .tint(sketch.tool == tool ? .accentColor : .secondary)
        .accessibilityLabel(label)
        .accessibilityAddTraits(sketch.tool == tool ? [.isSelected] : [])
    }
}
