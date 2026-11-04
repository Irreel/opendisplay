// The whole product in one screen, on an iPad or an iPhone, laid out as Figma
// v3.1 draws it: the mirror (C1) under a view-only zoom (C2), or, when the
// designer picks it, the whiteboard in its place (spec/PRD-BlankCanvas.md).
// Top left, where a sketch goes and what is on screen: the session pill (P1,
// P2) and under it the window switcher. Bottom left, a round button, the one
// way in and out of drawing (`DrawingButton`). While drawing, the
// prompt and Send at the top right, the tool panel at the bottom centre
// unless moved, and the sketch surface over the frozen frame. A card for
// each reply (M8). On Send, the sketch is seen leaving into the session pill
// (`SentSketchCard`).
//
// Two layers, on purpose. The mirror layer ignores the safe area, so the
// picture is full-bleed and the geometry the zoom maths works in is the same
// geometry `CanvasVideoHostView` lays the display layer out in. The sketch
// fills that layer too and is zoomed by the same `ZoomModel`, so ink stays on
// the part of the frame it was drawn on while the designer zooms; the Mac
// stretches what Done exports, the whole picture, over the whole frame.
// Everything else — the pills, the panel, the reply card, the notice —
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

    @ObservedObject var receiverModel: ReceiverController
    @ObservedObject var canvas: CanvasModel

    @StateObject private var sketch = SketchCanvasController()
    @State private var zoom = ZoomModel()
    /// The picture going into its print or out of it (`updatePrint`).
    @State private var printTween: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showConnection = false
    /// The session pill is open as the session menu.
    @State private var showSessions = false
    /// The window button is open as the window menu.
    @State private var showWindows = false
    /// "End without sending?" is up over End drawing.
    @State private var confirmEnd = false
    /// A window picked while there is ink on the page, waiting for the
    /// designer to say the ink can go.
    @State private var pendingSurface: CanvasSurface?
    /// The Ink Picker is open over the compact panel's swatch.
    @State private var showInks = false
    @State private var inkSwatch: CGRect?
    @State private var confirmDiscard = false
    @State private var viewSize = CGSize.zero
    /// Runs only while a freeze is outstanding (2 s at the most).
    @State private var freezeTicker: AnyCancellable?
    @State private var mirrorViews = MirrorViews()
    /// The sketch just sent, on its way into the send chip.
    @State private var sentSketch: SentSketch?
    @State private var sendTarget: CGRect?
    /// How many cards the send chip has taken in, so its icon can answer each.
    @State private var sendLandings = 0
    /// The session pill's width as laid out, for the top bar's layout.
    @State private var pillWidth: CGFloat = 0
    /// The send chip's, likewise.
    @State private var chipWidth: CGFloat = 0
    /// The designer's surface, remembered across launches (B1). The model
    /// decides whether it can be honoured with the Mac that is connected.
    @AppStorage("canvasSurface") private var storedSurface = CanvasSurface.mirror.rawValue
    /// Where the designer left the tool panel: the bottom centre until it is
    /// moved (Figma v3.1). A new key: the panel the old one placed held other
    /// controls, at the top.
    @AppStorage("canvasToolPanelEdge") private var storedPanelEdge = PanelEdge.bottom.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private var receiver: CanvasReceiver { receiverModel.receiver }

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

            // Over the chrome, which it flies across into the session pill.
            if let sent = sentSketch {
                SentSketchCard(sketch: sent, target: sendTarget) {
                    sendLandings += 1
                    if sentSketch?.id == sent.id { sentSketch = nil }
                }
                .id(sent.id)
                .ignoresSafeArea()
            }
        }
        .onPreferenceChange(SendTargetKey.self) { sendTarget = $0 }
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
            ConnectionDetailView(receiver: receiver, model: canvas)
        }
        // The only way out of RETRY other than a reconnect (M10), and it
        // throws away a sketch the designer has finished: ask first.
        // A window picked with ink on the page: the same question End
        // drawing asks, since the ink would go the same way.
        .alert("End without sending?", isPresented: Binding(
            get: { pendingSurface != nil },
            set: { if !$0 { pendingSurface = nil } })) {
            Button("Keep drawing", role: .cancel) {}
            Button("End without sending", role: .destructive) {
                if let chosen = pendingSurface { switchSurface(to: chosen) }
            }
        } message: {
            Text("Your sketch won\u{2019}t be saved.")
        }
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
            if !Self.isInDrawMode(state) {
                confirmEnd = false
                showInks = false
            }
            keepWhiteboardReady()
            updatePrint()
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
        // The designer's own switch (the window menu). The whiteboard goes
        // straight into drawing.
        .onChange(of: storedSurface) { raw in
            canvas.chooseSurface(CanvasSurface(rawValue: raw) ?? .mirror, pageViewport: pageViewport)
        }
        // The zoom belongs to the mirror; it must not carry over to a page,
        // nor come back stale when the mirror does.
        .onChange(of: canvas.surface) { _ in
            zoom.reset()
            keepWhiteboardReady()
            updatePrint()
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
        // A device lock ends the session, an app switch keeps it, and quitting
        // says goodbye (`ReceiverController`).
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
                                zoom: $zoom,
                                mirrorViews: mirrorViews)
            } else {
                WaitingForMacView(receiver: receiver) { showConnection = true }
            }

            // Under the ink, so a stroke at the edge stays on top of the frame.
            if isStreaming && !isBlank {
                FrozenFrameIndicator(active: isInDrawMode,
                                     picture: zoom.transformedRect(viewSize: size, videoSize: receiver.videoSize),
                                     paper: zoom.paper)
            }

            if isInDrawMode {
                SketchCanvas(controller: sketch, zoom: $zoom, videoSize: sketchVideoSize)
            }
        }
        .onAppear {
            viewSize = size
        }
        .onChange(of: size) { newSize in
            viewSize = newSize
            // The picture is laid out anew, so the strokes no longer sit on
            // what they were drawn over. They stay in the canvas for the next
            // entry (PRD G6).
            if isInDrawMode { canvas.rotated() }
            zoom.reset()
        }
    }

    // MARK: - The chrome layer (safe area)

    private var panelEdge: Binding<PanelEdge> {
        Binding(get: { PanelEdge(rawValue: storedPanelEdge) ?? .bottom },
                set: { storedPanelEdge = $0.rawValue })
    }

    /// Whether the chrome is up: with no Mac there is nothing to switch or
    /// draw on, and the waiting screen stands alone.
    private var showsChrome: Bool { receiver.connected || isInDrawMode }

    /// Start drawing and End drawing, on the mirror only: the whiteboard is
    /// always ready to draw.
    private var showsDrawingButton: Bool { showsChrome && !isBlank }

    /// Send needs a session to send to: on the whiteboard, which can be drawn
    /// on without one, it waits for one (Figma v3.1, 03a).
    private var canSend: Bool { canvas.canSend && canvas.hasClaudeSession }

    /// Whether the panel has to make do with one swatch for its five inks
    /// (`DrawTools`): on a screen too short along the panel's edge for all
    /// of them, as on an iPhone in portrait.
    private func compactPalette(in size: CGSize) -> Bool {
        let along = panelEdge.wrappedValue.isVertical ? size.height : size.width
        return along < DrawTools.length(compact: false) + 24
    }

    private func panelLength(in size: CGSize) -> CGFloat {
        DrawTools.length(compact: compactPalette(in: size))
    }

    /// The widest the pill may be: the row.
    private func pillMaxWidth(in size: CGSize) -> CGFloat {
        max(80, min(260, size.width - 2 * TopBarLayout.margin))
    }

    /// The session menu opens where the pill is, as wide as the screen leaves
    /// and as tall.
    private func sessionMenuSize(in size: CGSize) -> CGSize {
        CGSize(width: min(420, size.width - 2 * TopBarLayout.margin),
               height: max(120, size.height - 12 - TopBarLayout.margin))
    }

    /// The left of the top row: the session pill, measured, since it is as
    /// wide as the folder's name.
    private func leftWidth(in size: CGSize) -> CGFloat {
        guard showsChrome else { return 0 }
        return pillWidth > 0 ? pillWidth : min(220, pillMaxWidth(in: size))
    }

    /// The prompt pill at its narrowest: the rows are laid out for that, and
    /// it stretches to the room its row leaves, up to its full width.
    private static let promptMinWidth: CGFloat = 220
    private static let promptMaxWidth: CGFloat = 340

    private func replyCardWidth(in size: CGSize) -> CGFloat {
        min(360, size.width - 2 * TopBarLayout.margin)
    }

    private var panelOnTop: Bool { isInDrawMode && panelEdge.wrappedValue == .top }

    /// Which row each piece of the top of the screen takes. On an iPad, all
    /// one row unless a top-docked panel needs the room; on an iPhone, as
    /// many as it takes.
    private func topLayout(in size: CGSize) -> TopBarLayout {
        let right: CGFloat?
        if isInDrawMode {
            right = Self.promptMinWidth
        } else if canvas.sendIndicator == .waitingToResend {
            right = chipWidth > 0 ? chipWidth : 220
        } else {
            right = nil
        }
        return TopBarLayout(width: size.width,
                            left: leftWidth(in: size),
                            secondLeft: showsChrome ? WindowSwitcher.width : 0,
                            right: right,
                            panel: panelOnTop ? panelLength(in: size) : nil,
                            card: canvas.replyNotification == nil ? nil : replyCardWidth(in: size))
    }

    /// How wide the prompt pill is: the room its row leaves it, beside a
    /// palette that shares the row, or the left of the row.
    private func promptWidth(in size: CGSize, layout: TopBarLayout) -> CGFloat {
        let full = size.width - 2 * TopBarLayout.margin
        var room: CGFloat
        if panelOnTop && layout.panelRow == layout.rightRow {
            room = (size.width - panelLength(in: size)) / 2 - TopBarLayout.margin - TopBarLayout.gap
        } else if layout.rightRow == 0 {
            room = full - layout.left - TopBarLayout.gap
        } else if layout.rightRow == 1 {
            room = full - WindowSwitcher.width - TopBarLayout.gap
        } else {
            room = full
        }
        return max(Self.promptMinWidth, min(Self.promptMaxWidth, room))
    }

    /// Where the tool panel sits against the drawing button.
    private func bottomLayout(in size: CGSize) -> BottomBarLayout {
        BottomBarLayout(size: size, edge: panelEdge.wrappedValue,
                        panelLength: panelLength(in: size),
                        panelThickness: DrawTools.thickness,
                        button: showsDrawingButton
                            ? CGSize(width: DrawingButton.size, height: DrawingButton.size)
                            : nil)
    }

    /// A menu or a question is open over the screen.
    private var somethingOpen: Bool { showSessions || showWindows || confirmEnd || showInks }

    private func closeEverything() {
        showSessions = false
        showWindows = false
        confirmEnd = false
        showInks = false
    }

    private func chrome(size: CGSize) -> some View {
        let bottom = bottomLayout(in: size)
        return ZStack {
            if isInDrawMode {
                ControlPanel(edge: panelEdge, containerSize: size) { vertical in
                    DrawTools(sketch: sketch, vertical: vertical, compact: compactPalette(in: size),
                              inkPickerOpen: $showInks)
                }
                .offset(x: bottom.panelShift, y: -bottom.panelRaise)
                .padding(.horizontal, TopBarLayout.margin)
                .padding(.bottom, TopBarLayout.margin)
                .padding(.top, 12 + (panelOnTop ? TopBarLayout.offset(topLayout(in: size).panelRow) : 0))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: panelEdge.wrappedValue.alignment)
                .transition(.move(edge: panelEdge.wrappedValue.transitionEdge).combined(with: .opacity))
            }

            if !isInDrawMode, let notice = canvas.notice {
                NoticeBanner(text: notice.text) { canvas.dismissNotice() }
                    .padding(.bottom, noticeLift(in: size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

            // A tap anywhere else closes the open menu or question, as a tap
            // outside a popover would, and does nothing else: not a click on
            // the Mac, not a press on the panel.
            if somethingOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { closeEverything() }
                    .accessibilityHidden(true)
                    .zIndex(1)
            }

            if showInks, isInDrawMode, let swatch = inkSwatch {
                inkPicker(at: swatch, in: size)
                    .zIndex(2)
            }

            if showsDrawingButton {
                drawingButton(clearing: bottom.panelRaise)
                    .padding(.leading, TopBarLayout.margin)
                    .padding(.bottom, TopBarLayout.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .zIndex(confirmEnd ? 2 : 0)
            }

            // Over the panel and the rest, so the menus open over them.
            topBar(size: size)
                .zIndex(confirmEnd ? 0.5 : 3)
        }
        .coordinateSpace(name: "chrome")
        // The chrome alone is animated; the sketch surface in the mirror layer
        // is not (see the note on `body`).
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: isInDrawMode)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: canvas.replyNotification)
        .onPreferenceChange(InkSwatchFrameKey.self) { inkSwatch = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showInks)
    }

    /// The Ink Picker, 8 points off the panel on the side away from its
    /// edge, centred on the swatch and kept on the screen.
    private func inkPicker(at swatch: CGRect, in size: CGSize) -> some View {
        let edge = panelEdge.wrappedValue
        let half = InkPickerCapsule.length / 2
        let off = DrawTools.thickness / 2 + 8 + DrawTools.thickness / 2
        let center: CGPoint
        let anchor: UnitPoint
        switch edge {
        case .bottom:
            center = CGPoint(x: swatch.midX, y: swatch.midY - off)
            anchor = .bottom
        case .top:
            center = CGPoint(x: swatch.midX, y: swatch.midY + off)
            anchor = .top
        case .leading:
            center = CGPoint(x: swatch.midX + off, y: swatch.midY)
            anchor = .leading
        case .trailing:
            center = CGPoint(x: swatch.midX - off, y: swatch.midY)
            anchor = .trailing
        }
        let margin = TopBarLayout.margin
        let clamped = edge.isVertical
            ? CGPoint(x: center.x, y: min(max(center.y, margin + half), size.height - margin - half))
            : CGPoint(x: min(max(center.x, margin + half), size.width - margin - half), y: center.y)
        return InkPickerCapsule(sketch: sketch, vertical: edge.isVertical) { showInks = false }
            .position(clamped)
            .transition(.popOut(from: anchor))
    }

    /// The notice sits in the bottom row beside the drawing button where
    /// there is room, and in the row above it otherwise.
    private func noticeLift(in size: CGSize) -> CGFloat {
        let banner = min(560, size.width - 2 * TopBarLayout.margin)
        let beside = (size.width - banner) / 2 >= TopBarLayout.margin + DrawingButton.size + TopBarLayout.gap
        return showsDrawingButton && !beside
            ? TopBarLayout.margin + DrawingButton.size + 12
            : 24
    }

    /// Start drawing, or End drawing with "End without sending?" grown from
    /// it when there is ink to lose: above the tool panel, where the panel
    /// takes the row above the button (`raise`), as on an iPhone.
    private func drawingButton(clearing raise: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if confirmEnd {
                EndConfirmation {
                    confirmEnd = false
                    canvas.discard()
                }
                .padding(.bottom, raise)
                .transition(.popOut(from: .bottomLeading))
            }
            Group {
                if isInDrawMode {
                    DrawingButton(action: .end) {
                        if sketch.strokeCount > 0 {
                            confirmEnd.toggle()
                        } else {
                            canvas.discard()
                        }
                    }
                } else {
                    // Disabled while there is no connection, on a Mac that is
                    // not running Design Canvas, while a sketch is on its way,
                    // and while no Claude Code session is there to take the
                    // sketch: the session menu says which.
                    DrawingButton(action: .start) {
                        closeEverything()
                        canvas.enterDrawMode(viewport: currentViewport())
                    }
                    .disabled(!canvas.canEnterDrawMode || !canvas.hasClaudeSession)
                }
            }
        }
        // A spring with a little bounce (0.2), as the board times it.
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: confirmEnd)
        .animation(.easeInOut(duration: 0.2), value: isInDrawMode)
    }

    /// Laid out by `TopBarLayout`: each piece in its own row, at its own end,
    /// so a narrow screen stacks them rather than squeezing them.
    private func topBar(size: CGSize) -> some View {
        let layout = topLayout(in: size)
        return ZStack(alignment: .top) {
            if showsChrome {
                VStack(alignment: .leading, spacing: TopBarLayout.rowPitch - 44) {
                    HStack(alignment: .top, spacing: 8) {
                        // P1: where the sketch goes, and where a sent sketch
                        // lands. X26: if the target ends while the sketch is
                        // drawn and several are left, it asks for a choice,
                        // and Send waits for it.
                        ProjectPill(model: canvas,
                                    maxWidth: pillMaxWidth(in: size),
                                    menuSize: sessionMenuSize(in: size),
                                    landings: sendLandings,
                                    isOpen: $showSessions) {
                            showConnection = true
                        }
                        .background(GeometryReader { geo in
                            Color.clear
                                .preference(key: PillWidthKey.self, value: geo.size.width)
                                .preference(key: SendTargetKey.self, value: geo.frame(in: .global))
                        })
                        // The menu grows out of the pill, over what follows it.
                        .zIndex(1)
                    }
                    // Over the window button, which the session menu covers.
                    .zIndex(1)

                    WindowSwitcher(surface: canvas.surface,
                                   macName: canvas.macName,
                                   whiteboardAvailable: canvas.whiteboardAvailable,
                                   canSwitch: canvas.drawState == .live || isInDrawMode,
                                   menuWidth: min(340, size.width - 2 * TopBarLayout.margin),
                                   isOpen: $showWindows,
                                   onPick: pickSurface)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Over the rest of the top bar: the menus open down across
                // the rows under them.
                .zIndex(1)
            }

            Group {
                if isInDrawMode {
                    // It drops in at the top right as drawing starts (M1).
                    promptPill(width: promptWidth(in: size, layout: layout))
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if canvas.sendIndicator == .waitingToResend {
                    // RETRY is otherwise invisible: the picture is live again
                    // and Start drawing is disabled with nothing to explain it.
                    SendChip(indicator: canvas.sendIndicator) { confirmDiscard = true }
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: ChipWidthKey.self, value: geo.size.width)
                        })
                }
            }
            .padding(.top, TopBarLayout.offset(layout.rightRow))
            .frame(maxWidth: .infinity, alignment: .trailing)

            if let notification = canvas.replyNotification {
                ReplyNotificationCard(notification: notification, width: replyCardWidth(in: size)) {
                    canvas.dismissReplyNotification()
                }
                .padding(.top, TopBarLayout.offset(layout.cardRow))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(PillWidthKey.self) { pillWidth = $0 }
        .onPreferenceChange(ChipWidthKey.self) { chipWidth = $0 }
    }

    /// The prompt and Send in one pill (M4): top right, away from the drawing
    /// hand, so a sketch is not sent by accident. One line, optional; empty
    /// means no note is sent at all.
    private func promptPill(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 17))
                .foregroundStyle(Color.canvasSecondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            TextField("Note for Claude Code", text: $canvas.note,
                      prompt: Text("You can add comments here").foregroundColor(.canvasSecondary))
                .font(.subheadline)
                .submitLabel(.done)
                .autocorrectionDisabled()
            PanelIconButton(systemImage: "paperplane.fill", emphasis: .prominent, size: 36) {
                send()
            }
            .disabled(!canSend)
            .accessibilityLabel("Send the sketch to Claude Code")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(width: width, height: 44)
        .canvasGlass(in: Capsule())
    }

    /// A pick in the window menu. Ink on the page would be lost on the way,
    /// so with ink the same question as End drawing asks first.
    private func pickSurface(_ chosen: CanvasSurface) {
        showWindows = false
        guard chosen != canvas.surface else { return }
        if isInDrawMode && sketch.strokeCount > 0 {
            pendingSurface = chosen
        } else {
            switchSurface(to: chosen)
        }
    }

    private func switchSurface(to chosen: CanvasSurface) {
        // The model takes the new surface before drawing ends: ending it
        // runs `keepWhiteboardReady()`, which would otherwise still see the
        // whiteboard and start drawing again, on the way to the mirror.
        canvas.preferredSurface = chosen
        if isInDrawMode { canvas.discard() }
        storedSurface = chosen.rawValue
    }

    /// The held mirror goes into its print, and comes out of it when drawing
    /// ends (Figma v3.2, M9): the picture shrinks a little as the paper comes
    /// in around it, and grows back as the paper goes. Tweened here because
    /// the zoom is laid out by UIKit views, not animated by SwiftUI. The Pencil
    /// waits the 0.45 s it takes, so no stroke starts on a moving picture.
    private func updatePrint() {
        let held = isInDrawMode && !isBlank
        guard held != (zoom.rest != nil) else { return }
        var target = zoom
        if held {
            target.hold(viewSize: viewSize, videoSize: receiver.videoSize)
        } else {
            target.release(viewSize: viewSize, videoSize: receiver.videoSize)
        }
        printTween?.cancel()
        guard !reduceMotion else {
            zoom = target
            return
        }
        let from = zoom
        let duration = held ? 0.45 : 0.35
        let pen = sketch.canvasView.drawingGestureRecognizer
        if held { pen.isEnabled = false }
        printTween = Task { @MainActor in
            let start = CACurrentMediaTime()
            while !Task.isCancelled {
                let t = min(1, (CACurrentMediaTime() - start) / duration)
                // In: eases out, settling like a print dropped in place. Out:
                // eases in and out.
                let eased = held ? 1 - pow(1 - t, 3) : (t < 0.5 ? 4 * t * t * t : 1 - pow(2 - 2 * t, 3) / 2)
                zoom = ZoomModel.blend(from, target, progress: eased)
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
            pen.isEnabled = true
        }
    }

    /// The whiteboard is always ready to draw: whenever it is up and nothing
    /// else is happening, drawing starts on its own, after Send as well.
    private func keepWhiteboardReady() {
        guard isBlank, canvas.drawState == .live, canvas.canEnterDrawMode else { return }
        canvas.enterDrawMode(viewport: pageViewport)
    }

    /// The blank page's own rect, the whole view.
    private var pageViewport: CanvasViewport {
        CanvasViewport(width: Int(viewSize.width.rounded()),
                       height: Int(viewSize.height.rounded()),
                       scale: Double(UIScreen.main.scale))
    }

    /// The part of the view the mirror's picture covers right now: between the
    /// letterbox bars at the fit, the whole view once the zoom fills it.
    private func visiblePicture(in size: CGSize) -> CGRect {
        let screen = CGRect(origin: .zero, size: size)
        let drawn = zoom.transformedRect(viewSize: size, videoSize: receiver.videoSize)
        return drawn.isEmpty ? screen : drawn.intersection(screen)
    }

    /// Done (M5), and the card that shows the sketch leaving. The picture is
    /// taken before Done, while the screen still shows the frozen frame and
    /// the ink.
    private func send() {
        guard let png = sketch.sketchPNG() else { return }
        let rect = isBlank ? CGRect(origin: .zero, size: viewSize) : visiblePicture(in: viewSize)
        let picture = mirrorViews.snapshot(of: rect, blank: isBlank, ink: sketch.canvasView.superview)
        canvas.done(sketchPNG: png)
        // Refused, as too large to send: Draw Mode is still open.
        guard !isInDrawMode, let picture else { return }
        sentSketch = SentSketch(picture: picture, rect: rect, frozen: !isBlank)
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

private struct PillWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChipWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
            return "That sketch is too large to send. Erase some of it and tap Send again \u{2014} Draw Mode is still open."
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

/// Nothing to mirror yet — the receiver's status, and the setup steps that get
/// a Mac to connect (`SetupGuideCard`). This screen is all
/// the iPad says about a Mac that is not there, so the way to the details and
/// the log is on it. The status comes first and the steps follow in one centred
/// column, in either orientation. The steps run past the bottom of the screen,
/// so the first view is the status and the start of the steps, and the rest is
/// a scroll away.
private struct WaitingForMacView: View {
    @ObservedObject var receiver: CanvasReceiver
    let onConnectionDetails: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// An iPad, roomy both ways: the status gets air above it and a clear break
    /// before the steps. A phone keeps the tighter spacing.
    private var roomy: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    var body: some View {
        ScrollView {
            VStack(spacing: roomy ? 64 : 24) {
                status
                SetupGuideCard()
            }
            .padding(.horizontal, 32)
            .padding(.top, roomy ? 96 : 32)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemBackground))
    }

    private var status: some View {
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
            Button("Connection details", action: onConnectionDetails)
                .font(.subheadline.weight(.semibold))
        }
    }
}
