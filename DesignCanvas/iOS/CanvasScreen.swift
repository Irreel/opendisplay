// The whole iPad product in one screen: the mirror (C1) under a view-only
// zoom (C2) — or, when the designer picks it, a blank page in its place
// (spec/PRD-BlankCanvas.md) — the project the next sketch goes to (P1, P2), one
// draggable panel holding the surface and the Draw Mode entry (P3) or, in Draw
// Mode, the drawing tools, a card for each reply (M8), and — while Draw Mode is
// on — the sketch surface over the frozen frame.
//
// Two layers, on purpose. The mirror layer ignores the safe area, so the
// picture is full-bleed and the geometry the zoom maths works in is the same
// geometry `CanvasVideoHostView` lays the display layer out in. The sketch
// fills that layer too and is zoomed by the same `ZoomModel`, so ink stays on
// the part of the frame it was drawn on while the designer zooms; the Mac
// stretches what Done exports, the whole picture, over the whole frame.
// Everything else — the project pill, the panel, the reply card, the notice —
// is chrome that respects the safe area. None of it is ever in a sketch: Done
// exports the ink alone and the Mac lays it over its own frame.
//
// Everything that can be decided is decided in `CanvasModel` and `ZoomModel`,
// both of which are unit-tested; this file wires them to UIKit and to the
// scene lifecycle.

import Combine
import SwiftUI
import UIKit

struct CanvasScreen: View {

    @ObservedObject var receiverModel: ReceiverModel
    @ObservedObject var canvas: CanvasModel

    @StateObject private var sketch = SketchCanvasController()
    @State private var zoom = ZoomModel()
    @State private var showConnection = false
    @State private var confirmDiscard = false
    @State private var viewSize = CGSize.zero
    /// Runs only while a freeze is outstanding (2 s at the most).
    @State private var freezeTicker: AnyCancellable?
    /// The designer's surface, remembered across launches (B1). The model
    /// decides whether it can be honoured with the Mac that is connected.
    @AppStorage("canvasSurface") private var storedSurface = CanvasSurface.mirror.rawValue
    /// Where the designer left the panel. One position for both of its forms,
    /// so it changes in place when Draw Mode starts and ends.
    @AppStorage("canvasPanelEdge") private var storedPanelEdge = PanelEdge.top.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private var receiver: StreamReceiver { receiverModel.receiver }

    private var isStreaming: Bool {
        receiver.connected && receiver.videoSize != .zero
    }

    private var isInDrawMode: Bool { Self.isInDrawMode(canvas.drawState) }

    private static func isInDrawMode(_ state: DrawModeStateMachine.State) -> Bool {
        switch state {
        case .freezing, .drawing: return true
        case .live, .sending, .retry: return false
        }
    }

    /// The blank page is up in place of the mirror.
    private var isBlank: Bool { canvas.surface == .blank }

    /// The picture the sketch is laid over: none on the blank page, which
    /// makes the sketch cover the whole view.
    private var sketchVideoSize: CGSize { isBlank ? .zero : receiver.videoSize }

    /// What a sketch is sent for: the whole picture at scale 1, whatever the
    /// zoom is, or the whole view when the surface is the blank page — which
    /// is also the rect the Mac sizes its white page from (`viewport`).
    private var surfaceRect: CGRect {
        ZoomModel.sketchRect(videoSize: sketchVideoSize, in: viewSize)
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                mirror(size: geo.size)
            }
            .ignoresSafeArea()

            GeometryReader { geo in
                chrome(size: geo.size)
            }
        }
        // The blank page is white whatever the iPad's appearance is, so that
        // the ink reads as it will be sent. Everything drawn over it — the
        // pill, the panel, the status bar — has to be the light version, or
        // it is light on white.
        .preferredColorScheme(isBlank ? .light : nil)
        .statusBarHidden(isStreaming)
        .persistentSystemOverlays(isStreaming ? .hidden : .automatic)
        // Deliberately unanimated: the sketch surface is one UIKit object the
        // screen owns and hands back on every entry, and fading a removal out
        // would leave it in two hierarchies at once.
        .sheet(isPresented: $showConnection) {
            ConnectionDetailView(receiver: receiver, model: canvas,
                                 port: DesignCanvasiPad.port,
                                 serviceType: DesignCanvasiPad.serviceType)
        }
        // The only way out of RETRY other than a reconnect (M10), and it
        // throws away a sketch the designer has finished: ask first.
        .alert("Discard this sketch?", isPresented: $confirmDiscard) {
            Button("Keep", role: .cancel) {}
            Button("Discard", role: .destructive) { canvas.discard() }
        } message: {
            Text("It hasn\u{2019}t reached Claude Code yet. If you discard it, it won\u{2019}t be sent and can\u{2019}t be brought back.")
        }
        // The freeze deadline only needs a clock while the freeze is
        // outstanding.
        .onChange(of: canvas.drawState) { state in
            updateFreezeTicker(for: state)
        }
        // The round is over: empty the canvas and tell the model it happened.
        .onChange(of: canvas.shouldClearStrokes) { shouldClear in
            guard shouldClear else { return }
            sketch.clear()
            canvas.strokesCleared()
        }
        .onChange(of: sketch.strokeCount) { count in
            canvas.strokesChanged(count: count)
        }
        // The designer's own switch. Picking Blank goes straight into Draw
        // Mode; Cancel there brings this panel back, on the page.
        .onChange(of: storedSurface) { raw in
            canvas.chooseSurface(CanvasSurface(rawValue: raw) ?? .mirror,
                                 pageViewport: CanvasViewport(width: Int(viewSize.width.rounded()),
                                                              height: Int(viewSize.height.rounded()),
                                                              scale: Double(UIScreen.main.scale)))
        }
        // The zoom belongs to the mirror; it must not carry over to a page,
        // nor come back stale when the mirror does.
        .onChange(of: canvas.surface) { _ in
            zoom.reset()
        }
        .onAppear {
            canvas.preferredSurface = CanvasSurface(rawValue: storedSurface) ?? .mirror
            UIApplication.shared.isIdleTimerDisabled = true
            receiverModel.start()
        }
        .onChange(of: scenePhase) { phase in
            Log.info("scenePhase -> \(String(describing: phase))")
            switch phase {
            case .active: receiverModel.sceneDidActivate()
            case .background: receiverModel.sceneDidBackground()
            default: break
            }
        }
        // The same lock, app-switch and terminate handling OpenDisplay's
        // receiver uses: a device lock ends the session, an app switch keeps it.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            receiverModel.deviceWillLock()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            receiverModel.deviceDidUnlock()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willTerminateNotification)) { _ in
            receiverModel.appWillTerminate()
        }
    }

    // MARK: - The mirror layer (full bleed)

    private func mirror(size: CGSize) -> some View {
        ZStack {
            Color.black

            if isBlank {
                // Rendered here, not streamed: it needs no frame from the Mac,
                // so it is up even before the mirror's first picture (B4).
                Color.white
                    .accessibilityLabel("Blank canvas")
            } else if isStreaming {
                CanvasVideoView(displayLayer: receiver.displayLayer,
                                videoSize: receiver.videoSize,
                                zoom: $zoom)
            } else {
                WaitingForMacView(receiver: receiver) { showConnection = true }
            }

            if isInDrawMode {
                SketchCanvas(controller: sketch, zoom: $zoom, videoSize: sketchVideoSize)
            }
        }
        .onAppear {
            viewSize = size
            receiver.setOrientation(portrait: size.height > size.width)
        }
        .onChange(of: size) { newSize in
            viewSize = newSize
            receiver.setOrientation(portrait: newSize.height > newSize.width)
            // The Mac rebuilds its display for the new dimensions, so the frame
            // this sketch was frozen on is gone. The strokes stay in the canvas
            // for the next entry (PRD G6).
            if isInDrawMode { canvas.rotated() }
            zoom.reset()
        }
    }

    // MARK: - The chrome layer (safe area)

    private var panelEdge: Binding<PanelEdge> {
        Binding(get: { PanelEdge(rawValue: storedPanelEdge) ?? .top },
                set: { storedPanelEdge = $0.rawValue })
    }

    /// The panel's width along a row: five 36-point buttons, five 34-point
    /// swatches and three dividers in Draw Mode, three buttons and a divider
    /// between sketches, with 4-point gaps and padding.
    private var panelRowWidth: CGFloat { isInDrawMode ? 413 : 129 }

    /// What one side of the top row needs beside a top-docked panel. On the
    /// left: Cancel, and the project pill when a session must be picked. On
    /// the right: the note at its placeholder width and Send.
    private var drawModeSideWidth: CGFloat {
        let left: CGFloat = 16 + 44 + (canvas.sessions.needsPick ? 8 + 220 : 0)
        let right: CGFloat = 16 + 139 + 8 + 44
        return max(left, right) + 8
    }

    /// In Draw Mode the top row also holds Cancel, the note and Send. The
    /// palette sits in that row, between them, as in the design; only where
    /// the screen is too narrow for that does it take the row below.
    private func panelDropsBelowBar(in size: CGSize) -> Bool {
        panelEdge.wrappedValue == .top && isInDrawMode
            && (size.width - panelRowWidth) / 2 < drawModeSideWidth
    }

    /// How wide the note may grow before it would run into a palette that
    /// shares its row.
    private func noteMaxWidth(in size: CGSize) -> CGFloat {
        guard panelEdge.wrappedValue == .top, !panelDropsBelowBar(in: size) else { return 320 }
        // The field's own icon and padding take 68 points, Send and the gaps 60.
        return min(320, max(71, (size.width - panelRowWidth) / 2 - 16 - 68 - 8 - 44 - 8))
    }

    /// A top-docked panel and the reply card want the same strip of a narrow
    /// screen. The card gives way and sits one row lower. In Draw Mode the
    /// card is already a row down, under the note, and only moves again when
    /// the palette has dropped into that row too.
    private func replyCardDropsBelowPanel(in size: CGSize) -> Bool {
        guard panelEdge.wrappedValue == .top else { return false }
        if isInDrawMode { return panelDropsBelowBar(in: size) }
        return (size.width - panelRowWidth) / 2 < 16 + 340 + 8
    }

    private func chrome(size: CGSize) -> some View {
        ZStack {
            topBar(size: size)

            // With no Mac there is nothing to switch or draw on: the waiting
            // screen stands alone.
            if receiver.connected || isInDrawMode {
                ControlPanel(edge: panelEdge, containerSize: size) { vertical in
                    if isInDrawMode {
                        DrawTools(model: canvas, sketch: sketch, vertical: vertical)
                            .transition(.opacity)
                    } else {
                        LiveControls(model: canvas, storedSurface: $storedSurface, vertical: vertical) {
                            canvas.enterDrawMode(viewport: currentViewport())
                        }
                        .transition(.opacity)
                    }
                }
                .padding(12)
                .padding(.top, panelDropsBelowBar(in: size) ? 60 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: panelEdge.wrappedValue.alignment)
            }

            if !isInDrawMode, let notice = canvas.notice {
                NoticeBanner(text: notice.text) { canvas.dismissNotice() }
                    .padding(.bottom, panelEdge.wrappedValue == .bottom ? 96 : 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .coordinateSpace(name: "chrome")
        // The chrome alone is animated; the sketch surface in the mirror layer
        // is not (see the note on `body`).
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: isInDrawMode)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: canvas.replyNotification)
    }

    private func topBar(size: CGSize) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if isInDrawMode {
                // M6: leaves Draw Mode, keeps the strokes for the next entry.
                PanelIconButton(systemImage: "xmark") { canvas.cancel() }
                    .padding(4)
                    .canvasGlass(in: Capsule())
                    .accessibilityLabel("Leave Draw Mode and keep the sketch")
                // X26: the session this sketch would have gone to ended while
                // it was being drawn, and several are left. Send waits for a
                // choice, made here.
                if canvas.sessions.needsPick {
                    ProjectPill(model: canvas) { showConnection = true }
                }
            } else if receiver.connected {
                ProjectPill(model: canvas) { showConnection = true }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                if isInDrawMode {
                    noteAndSend(size: size)
                } else if canvas.sendIndicator != .none {
                    // SENDING and RETRY are otherwise invisible: the picture
                    // is live again and Draw is disabled with nothing to
                    // explain it.
                    SendChip(indicator: canvas.sendIndicator) { confirmDiscard = true }
                }
                if let notification = canvas.replyNotification {
                    ReplyNotificationCard(notification: notification) {
                        canvas.dismissReplyNotification()
                    }
                    .padding(.top, replyCardDropsBelowPanel(in: size) ? 60 : 0)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func noteAndSend(size: CGSize) -> some View {
        HStack(spacing: 8) {
            // M4: one line, optional. Empty means no note is sent at all.
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.canvasSecondary)
                    .frame(width: 24, height: 24)
                TextField("Add a note", text: $canvas.note,
                          prompt: Text("Add a note").foregroundColor(.canvasSecondary))
                    .font(.system(size: 15))
                    .tracking(Self.noteTracking)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .frame(width: min(noteWidth, noteMaxWidth(in: size)))
            }
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .frame(height: 44)
            .canvasGlass(in: Capsule())

            PanelIconButton(systemImage: "paperplane.fill", emphasis: .prominent, size: 36) {
                guard let png = sketch.sketchPNG() else { return }
                canvas.done(sketchPNG: png)
            }
            .disabled(!canvas.canSend)
            .padding(4)
            .canvasGlass(in: Capsule())
            .accessibilityLabel("Send the sketch to Claude Code")
        }
    }

    private static let noteTracking: CGFloat = -0.6

    /// The note field hugs what it holds, the placeholder when empty. How far
    /// it may grow is `noteMaxWidth(in:)`.
    private var noteWidth: CGFloat {
        let shown = canvas.note.isEmpty ? "Add a note" : canvas.note
        let width = (shown as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: 15),
            .kern: Self.noteTracking,
        ]).width
        return ceil(width) + 4
    }

    /// The surface the sketch was drawn on, stored with the round so the Mac
    /// knows what it was made at.
    private func currentViewport() -> CanvasViewport {
        CanvasViewport(width: Int(surfaceRect.width.rounded()),
                       height: Int(surfaceRect.height.rounded()),
                       scale: Double(UIScreen.main.scale))
    }

    private func updateFreezeTicker(for state: DrawModeStateMachine.State) {
        guard case .freezing = state else {
            freezeTicker?.cancel()
            freezeTicker = nil
            return
        }
        guard freezeTicker == nil else { return }
        freezeTicker = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { _ in canvas.tick() }
    }
}

// MARK: - Pieces

extension DrawModeStateMachine.Notice {
    /// What the banner and the connection sheet say about this notice.
    var text: String {
        switch self {
        case .noFrame:
            return "The Mac had no frame for that moment, so Draw Mode ended. Your sketch was kept."
        case .freezeTimedOut:
            return "The Mac did not answer in time, so Draw Mode ended. Your sketch was kept."
        case .interruptedByRotation:
            return "Rotating rebuilds the Mac's display, so Draw Mode ended. Your sketch was kept."
        case .interruptedByLinkLoss:
            return "The connection dropped, so Draw Mode ended. Your sketch was kept."
        case .sketchTooLarge:
            return "That sketch is too large to send. Erase some of it and tap Done again \u{2014} Draw Mode is still open."
        }
    }
}

/// Where a sketch that has left Draw Mode has got to (`technical_doc.md`
/// section 11: a link that drops mid-upload must read as "will resend"), and,
/// while it waits to be resent, the way to give up on it.
private struct SendChip: View {
    let indicator: CanvasModel.SendIndicator
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.footnote)
                    .foregroundStyle(indicator == .waitingToResend ? Color.canvasWarningMark : Color.canvasSecondary)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)

            // A Mac that has been quit would otherwise leave Draw disabled and
            // this chip up for ever (M10).
            if indicator == .waitingToResend {
                PanelIconButton(systemImage: "trash", tint: .canvasDangerText, action: onDiscard)
                    .accessibilityLabel("Give up on the sketch waiting to be resent")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, indicator == .waitingToResend ? 4 : 14)
        .frame(height: 44)
        .canvasGlass(in: Capsule())
    }

    private var icon: String {
        indicator == .waitingToResend ? "clock.arrow.circlepath" : "paperplane"
    }

    private var title: String {
        switch indicator {
        case .sending, .none: return "Sending sketch\u{2026}"
        case .waitingToResend: return "Sketch kept \u{2014} will resend"
        }
    }

    private var label: String {
        switch indicator {
        case .sending, .none:
            return "Sending the sketch to the Mac"
        case .waitingToResend:
            return "Sketch kept \u{2014} it will be resent when the Mac reconnects"
        }
    }
}

private struct NoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.canvasWarningMark)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 8, y: 2)
        .padding(.horizontal, 16)
    }
}

/// Nothing to mirror yet — the two facts OpenDisplay's idle screen shows,
/// without its artwork (custom icons are deferred, plan ruling 9). This screen
/// is all the iPad says about a Mac that is not there, so the way to the
/// details and the log is on it.
private struct WaitingForMacView: View {
    @ObservedObject var receiver: StreamReceiver
    let onConnectionDetails: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "laptopcomputer.and.arrow.down")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Design Canvas")
                .font(.largeTitle.bold())
            HStack(spacing: 8) {
                StatusDot(state: receiver.connected ? .up : .down)
                Text(receiver.status)
                    .font(.callout)
                    .foregroundStyle(Color.canvasSecondary)
            }
            Text("Start the Design Canvas Mac app and pick this \(deviceKind), by cable or on the same WiFi. Keep this app open — mirroring starts on its own.")
                .font(.subheadline)
                .foregroundStyle(Color.canvasSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Connection details", action: onConnectionDetails)
                .font(.subheadline.weight(.semibold))
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
