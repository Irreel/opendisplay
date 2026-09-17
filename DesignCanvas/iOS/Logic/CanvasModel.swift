// The iPad's Draw Mode view-model: it owns the Draw Mode state machine, turns
// its effects into calls on the receiver, and holds everything the screen
// draws — the rounds list, the current notice, the channel and project the Mac
// reports on its ping.
//
// The receiver is behind `CanvasReceiving` so this file stays free of UIKit and
// of `StreamReceiver` itself: it is compiled into the hostless test bundle as
// well as the app, and `ReceiverAdapter` is the only thing that knows both
// sides (see project.yml, and DesignCanvas/iOS/ReceiverAdapter.swift).

import Combine
import Foundation

/// What `CanvasModel` needs from the receiver. `StreamReceiver` provides all of
/// it; `ReceiverAdapter` is the conformance.
protocol CanvasReceiving: AnyObject {
    /// A Mac is on the other end of the socket right now.
    var isConnected: Bool { get }
    /// That Mac said `welcome.canvas: true` — it is a Design Canvas Mac.
    var supportsCanvas: Bool { get }
    /// Capture ms of the frame on screen, nil before the first one lands.
    func currentCaptureMs() -> Int64?
    /// Hold the picture (the freeze half of M1) or let it run again.
    func setFrozen(_ frozen: Bool)
    /// Put a canvas message on the wire. True means the socket write
    /// completed — there is no ack for these (plan ruling 5).
    func sendCanvas(_ message: [String: Any], completion: @escaping (Bool) -> Void)
}

@MainActor
final class CanvasModel: ObservableObject {

    private let receiver: CanvasReceiving
    /// Milliseconds since the epoch: stamps the `t` of outgoing messages.
    private let nowMs: () -> Double
    /// Monotonic seconds: drives the freeze deadline, which must not move when
    /// the wall clock does.
    private let uptime: () -> TimeInterval

    private var machine = DrawModeStateMachine()

    @Published private(set) var drawState: DrawModeStateMachine.State = .live
    /// Newest first, at most `CanvasWire.roundsSnapshotLimit` (M8).
    @Published private(set) var rounds: [CanvasRound] = []
    @Published private(set) var notice: DrawModeStateMachine.Notice?
    /// `.none` until a ping says otherwise (P1).
    @Published private(set) var channel: ChannelState = .none
    @Published private(set) var project: String?
    /// The optional one-line note (M4). Bound to the text field.
    @Published var note = ""
    /// Edge flag: the sketch has been sent or thrown away, so the canvas view
    /// should empty itself and call `strokesCleared()`.
    @Published private(set) var shouldClearStrokes = false

    /// The zoom, viewport and frame captured when Draw Mode was entered. The
    /// sketch is drawn on that frame, so that is what the Mac is told about —
    /// not whatever the live picture has moved on to.
    private var entryZoomRect: NormalizedRect = .full
    private var entryViewport = CanvasViewport(width: 0, height: 0, scale: 1)
    private var entryCaptureMs: Int64 = 0
    /// Built by `done`, kept until the send lands so a retry after a link loss
    /// puts the identical bytes back on the wire (plan ruling 5).
    private var pendingAnnotation: AnnotationMessage?

    /// ISO-8601 with fractional seconds in UTC, the format the daemon's own
    /// `createdAt` uses, so a round this device invents for a reply about an
    /// annotation it has no snapshot for still sorts with the rest.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(receiver: CanvasReceiving,
         nowMs: @escaping () -> Double,
         uptime: @escaping () -> TimeInterval) {
        self.receiver = receiver
        self.nowMs = nowMs
        self.uptime = uptime
    }

    // MARK: - What the screen asks

    /// Draw Mode is reachable only on a live, connected, Design Canvas session
    /// (P3, and requirement 6 of the brief: a plain OpenDisplay Mac leaves the
    /// button disabled).
    var canEnterDrawMode: Bool {
        machine.state == .live && receiver.isConnected && receiver.supportsCanvas
    }

    /// Done is live only in DRAWING with at least one stroke (ruling 7).
    var canSend: Bool { machine.canSend }

    /// What is happening to a sketch that has left Draw Mode but not landed.
    /// SENDING and RETRY look identical to a user otherwise — the picture is
    /// live again and Draw is disabled with nothing to explain it — and
    /// technical_doc.md section 11 requires a link drop mid-upload to be
    /// visible as "will resend".
    enum SendIndicator: Equatable {
        case none
        case sending
        case waitingToResend
    }

    var sendIndicator: SendIndicator {
        switch drawState {
        case .sending: return .sending
        case .retry: return .waitingToResend
        case .live, .freezing, .drawing: return .none
        }
    }

    // MARK: - Draw Mode

    /// Freeze the picture and ask the Mac to keep the same frame (M1, D9).
    /// `zoomRect` and `viewport` are what the sketch will be sent with.
    func enterDrawMode(zoomRect: NormalizedRect, viewport: CanvasViewport) {
        guard let captureMs = receiver.currentCaptureMs() else {
            // Nothing has been displayed yet, so there is no frame to name and
            // no point freezing on it (M7's message, without the round trip).
            notice = .noFrame
            return
        }
        entryCaptureMs = captureMs
        entryZoomRect = zoomRect
        entryViewport = viewport
        // Whatever the last exit said, it is not about this sketch.
        notice = nil
        apply(.enterDrawMode(now: uptime()))
    }

    func strokesChanged(count: Int) {
        apply(.strokeCountChanged(count))
    }

    /// Send the finished sketch (M5). The message is built from the state Draw
    /// Mode was entered with, so a late live frame cannot change what the Mac
    /// crops.
    func done(sketchPNG: Data) {
        // Only build and store the message when the machine will accept it.
        // Otherwise a Done the machine refuses — no strokes, or a round still
        // stranded in RETRY — would leave its payload behind as the thing the
        // next `hello` resends.
        guard canSend else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAnnotation = AnnotationMessage(sketchPNG: sketchPNG,
                                              zoomRect: entryZoomRect,
                                              viewport: entryViewport,
                                              note: trimmed.isEmpty ? nil : trimmed,
                                              t: nowMs())
        apply(.done)
    }

    /// Leave without sending, keeping the strokes for the next entry (M6).
    func cancel() { apply(.cancel) }

    /// Leave without sending and throw the strokes away.
    func discard() { apply(.discard) }

    /// The iPad turned: the Mac is rebuilding its display, so the frozen frame
    /// no longer matches anything. The strokes stay in the canvas (PRD G6).
    func rotated() { apply(.rotated) }

    /// The canvas emptied itself after `shouldClearStrokes`.
    func strokesCleared() { shouldClearStrokes = false }

    func dismissNotice() { notice = nil }

    /// Drives the freeze deadline. The screen runs this only while freezing.
    func tick() { apply(.tick(now: uptime())) }

    // MARK: - What the receiver reports

    func connectionChanged(connected: Bool) {
        // `canEnterDrawMode` reads the receiver, so the screen has to be told
        // that the answer may have changed.
        objectWillChange.send()
        guard !connected else { return }
        // The channel and the project are things a *connected* Mac told us.
        // With the Mac gone the second hop cannot be up, and P1 asks the panel
        // to show both hops honestly rather than leave the last ping's answer
        // standing. The next ping repopulates them; the receiver's own
        // `CanvasReceiverState` only resets when a new connection is adopted,
        // which can be much later.
        channel = .none
        project = nil
        apply(.linkLost)
    }

    /// A `welcome` landed. On a canvas session this is the resend trigger: the
    /// link is back up and a sketch stranded in RETRY goes out again.
    func welcomeReceived(canvas: Bool) {
        objectWillChange.send()
        guard canvas else { return }
        apply(.helloReceived)
    }

    /// The Mac's ping carries its channel state and selected project (P1).
    func pingReceived(channel: String?, project: String?) {
        self.channel = channel.flatMap(ChannelState.init(rawValue:)) ?? .none
        self.project = project
    }

    /// A canvas control message from the Mac. Anything that does not parse is
    /// ignored, exactly as an unknown type is (PROTOCOL.md 6).
    func canvasMessage(type: String, object: [String: Any]) {
        switch type {
        case CanvasWire.frozen:
            guard let frozen = FrozenMessage(json: object) else { return }
            apply(.frozen(ok: frozen.ok))
        case CanvasWire.rounds:
            guard let snapshot = RoundsMessage(json: object) else { return }
            rounds = Array(snapshot.rounds.prefix(CanvasWire.roundsSnapshotLimit))
        case CanvasWire.agentReply:
            guard let reply = AgentReplyMessage(json: object) else { return }
            merge(reply)
        default:
            return
        }
    }

    // MARK: - The state machine and its effects

    private func apply(_ event: DrawModeStateMachine.Event) {
        let effects = machine.handle(event)
        // Published before the effects run: an effect can feed the machine
        // again (a send that completes at once), and that nested result must
        // be the one that stands.
        if machine.state != drawState { drawState = machine.state }
        for effect in effects { run(effect) }
    }

    private func run(_ effect: DrawModeStateMachine.Effect) {
        switch effect {
        case .pauseSync:
            receiver.setFrozen(true)
        case .resumeSync:
            receiver.setFrozen(false)
        case .sendFreeze:
            sendFreeze()
        case .sendAnnotation:
            sendAnnotation()
        case .clearStrokes:
            shouldClearStrokes = true
            pendingAnnotation = nil
            note = ""
        case .show(let notice):
            self.notice = notice
        }
    }

    private func sendFreeze() {
        // `pauseSync` ran first, so the picture is already held and this names
        // the frame the user is looking at. It can only be nil if the link
        // dropped in between, and the frame from the entry check is then still
        // the best thing to ask for.
        let captureMs = receiver.currentCaptureMs() ?? entryCaptureMs
        let freeze = FreezeMessage(captureMs: captureMs, zoomRect: entryZoomRect, t: nowMs())
        send(CanvasWire.freeze, freeze.json) { _ in }
    }

    private func sendAnnotation() {
        guard let annotation = pendingAnnotation else { return }
        send(CanvasWire.annotation, annotation.json) { [weak self] ok in
            // Main queue, by StreamReceiver's contract.
            self?.apply(ok ? .sent : .linkLost)
        }
    }

    private func send(_ type: String, _ body: [String: Any],
                      completion: @escaping (Bool) -> Void) {
        var message = body
        message["type"] = type
        receiver.sendCanvas(message, completion: completion)
    }

    // MARK: - Rounds

    /// A live status change (ruling 4). It updates the round it names, or — if
    /// this device has no snapshot of that round — becomes one at the front.
    private func merge(_ reply: AgentReplyMessage) {
        if let index = rounds.firstIndex(where: { $0.annotationId == reply.annotationId }) {
            var round = rounds[index]
            round.status = reply.status
            // A `queued`/`sent` relay carries no text; it must not wipe the
            // text an earlier reply already delivered.
            if let message = reply.message { round.message = message }
            if let prUrl = reply.prUrl { round.prUrl = prUrl }
            rounds[index] = round
            return
        }
        let created = Date(timeIntervalSince1970: reply.t / 1000)
        rounds.insert(CanvasRound(annotationId: reply.annotationId,
                                  createdAt: Self.iso.string(from: created),
                                  status: reply.status,
                                  message: reply.message,
                                  prUrl: reply.prUrl,
                                  note: nil),
                      at: 0)
        if rounds.count > CanvasWire.roundsSnapshotLimit {
            rounds.removeLast(rounds.count - CanvasWire.roundsSnapshotLimit)
        }
    }
}
