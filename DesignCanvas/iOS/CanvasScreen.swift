// The whole iPad product in one screen: the mirror (C1) under a view-only
// zoom (C2), a floating panel with connection status (P1, P2), the Draw Mode
// entry (P3) and the replies list (M8), and — while Draw Mode is on — the
// sketch surface over the frozen frame.
//
// Two layers, on purpose. The mirror layer ignores the safe area, so the
// picture is full-bleed and the geometry the zoom maths works in is the same
// geometry `CanvasVideoHostView` lays the display layer out in. The sketch
// sits in that layer too, at exactly the rect the video covers on screen,
// because the Mac stretches the sketch over the crop it makes from `zoomRect`.
// Everything else — the status panel, the tool panel, the notice — is chrome
// that respects the safe area.
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
    @State private var showReplies = false
    @State private var viewSize = CGSize.zero
    /// Runs only while a freeze is outstanding (2 s at the most).
    @State private var freezeTicker: AnyCancellable?
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

    /// Where the video is on screen: what the sketch has to line up with.
    private var videoRect: CGRect {
        let drawn = zoom.transformedRect(viewSize: viewSize, videoSize: receiver.videoSize)
        let visible = drawn.intersection(CGRect(origin: .zero, size: viewSize))
        return visible.isNull ? CGRect(origin: .zero, size: viewSize) : visible
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                mirror(size: geo.size)
            }
            .ignoresSafeArea()

            chrome
        }
        .statusBarHidden(isStreaming)
        .persistentSystemOverlays(isStreaming ? .hidden : .automatic)
        .animation(.easeInOut(duration: 0.15), value: isInDrawMode)
        .sheet(isPresented: $showConnection) {
            ConnectionDetailView(receiver: receiver, model: canvas,
                                 port: DesignCanvasiPad.port,
                                 serviceType: DesignCanvasiPad.serviceType)
        }
        .sheet(isPresented: $showReplies) {
            AgentRepliesView(model: canvas)
        }
        // Zoom is locked while the sketch is pinned to its frame, and the
        // freeze deadline only needs a clock while the freeze is outstanding.
        .onChange(of: canvas.drawState) { state in
            zoom.isLocked = Self.isInDrawMode(state)
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
        .onAppear {
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

            if isStreaming {
                CanvasVideoView(displayLayer: receiver.displayLayer,
                                videoSize: receiver.videoSize,
                                zoom: $zoom)
            } else {
                WaitingForMacView(receiver: receiver)
            }

            if isInDrawMode {
                SketchCanvas(controller: sketch)
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)
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

    private var chrome: some View {
        VStack(spacing: 0) {
            if !isInDrawMode {
                panel.padding(.top, 12)
            }
            Spacer(minLength: 0)
            if isInDrawMode {
                DrawModeOverlay(model: canvas, sketch: sketch)
                    .padding(.bottom, 16)
            } else if let notice = canvas.notice {
                NoticeBanner(text: notice.text) { canvas.dismissNotice() }
                    .padding(.bottom, 24)
            }
        }
    }

    private var panel: some View {
        HStack(spacing: 8) {
            ConnectionStatusView(receiver: receiver, model: canvas) {
                showConnection = true
            }

            Divider().frame(height: 26)

            // P3: the way in. Disabled while there is no connection, and on a
            // Mac that is not running Design Canvas.
            Button {
                canvas.enterDrawMode(zoomRect: zoom.visibleRect(viewSize: viewSize,
                                                                videoSize: receiver.videoSize),
                                     viewport: currentViewport())
            } label: {
                Label("Draw", systemImage: "pencil.and.outline")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canvas.canEnterDrawMode)
            .accessibilityLabel("Enter Draw Mode")

            Button {
                showReplies = true
            } label: {
                Label("Replies", systemImage: "text.bubble")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Agent replies")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8, y: 2)
    }

    /// The surface the sketch was drawn on, stored with the round so the Mac
    /// knows what it was made at.
    private func currentViewport() -> CanvasViewport {
        CanvasViewport(width: Int(videoRect.width.rounded()),
                       height: Int(videoRect.height.rounded()),
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
        }
    }
}

private struct NoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
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
/// without its artwork (custom icons are deferred, plan ruling 9).
private struct WaitingForMacView: View {
    @ObservedObject var receiver: StreamReceiver

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
                    .foregroundStyle(.secondary)
            }
            Text("Start the Design Canvas Mac app and pick this \(deviceKind), by cable or on the same WiFi. Keep this app open — mirroring starts on its own.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
