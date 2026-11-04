// The iPad's Draw Mode view-model: it owns the Draw Mode state machine, turns
// its effects into calls on the receiver, and holds everything the screen
// draws — the rounds list, the current notice, the channel and project the Mac
// reports in its `status`.
//
// The receiver is behind `CanvasReceiving` so this file stays free of UIKit and
// of the socket: it is unit-tested against a fake, and `ReceiverAdapter` is the
// only thing that knows both sides.

import Combine
import Foundation

/// What `CanvasModel` needs from the receiver. `CanvasReceiver` provides all
/// of it; `ReceiverAdapter` is the conformance.
protocol CanvasReceiving: AnyObject {
    /// A Mac said hello on the other end of the socket.
    var isConnected: Bool { get }
    /// The number of the frame on screen, nil before the first one lands.
    func currentFrame() -> UInt64?
    /// Hold the picture (the freeze half of M1) or let it run again.
    func setFrozen(_ frozen: Bool)
    /// Put a canvas message on the wire, with `attachment` riding along. True
    /// means the socket write completed — there is no ack (plan ruling 5).
    func send(_ type: String, _ object: [String: Any], attachment: Data,
              completion: @escaping (Bool) -> Void)
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
    /// The outcome the screen is announcing (M8): the newest round that
    /// reached one while this device was watching. Nil once dismissed.
    @Published private(set) var replyNotification: ReplyNotification?
    /// `.none` until the Mac's `status` says otherwise (P1).
    @Published private(set) var channel: ChannelState = .none
    @Published private(set) var project: String?
    /// The connected Mac's own name, from its hello, for the window menu.
    @Published private(set) var macName: String?
    /// The surface the designer chose (B1). Persisted by the screen.
    @Published var preferredSurface: CanvasSurface = .mirror
    /// The Claude Code sessions the Mac is connected to and which one the next
    /// sketch goes to (X21 to X26). Empty until the Mac sends a `sessions`
    /// message.
    @Published private(set) var sessions: SessionsMessage = .empty
    /// The optional one-line note (M4). Bound to the text field.
    @Published var note = ""
    /// Edge flag: the sketch has been sent or thrown away, so the canvas view
    /// should empty itself and call `strokesCleared()`.
    @Published private(set) var shouldClearStrokes = false

    /// The viewport and frame captured when Draw Mode was entered. The sketch
    /// is drawn on that frame, so that is what the Mac is told about — not
    /// whatever the live picture has moved on to.
    private var entryViewport = CanvasViewport(width: 0, height: 0, scale: 1)
    private var entryFrame: UInt64 = 0
    /// The frame the last `freeze` named, so only its own `frozen` answers it.
    private var freezeFrame: UInt64?
    /// What the sketch in progress was drawn on. Fixed at entry: the surface the screen shows later says nothing about this sketch.
    private var entryBase: CanvasSurface = .mirror
    /// Built by `done`, kept until the send lands so a retry after a link loss
    /// puts the identical bytes back on the wire (plan ruling 5).
    private var pendingAnnotation: AnnotationMessage?
    /// The last outcome a live reply put on screen, so a duplicate relay of it
    /// is not announced twice.
    private var lastAnnounced: ReplyNotification?

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

    /// What the iPad shows: the blank page only when the designer chose it and
    /// a Mac is on the other end to take the sketch (B3).
    var surface: CanvasSurface {
        preferredSurface == .blank && receiver.isConnected ? .blank : .mirror
    }

    /// The whiteboard needs a Mac on the other end to take its sketch (B3).
    var whiteboardAvailable: Bool { receiver.isConnected }

    /// Draw Mode is reachable only on a live, connected session (P3).
    var canEnterDrawMode: Bool {
        machine.state == .live && receiver.isConnected
    }

    /// Done is live only in DRAWING with at least one stroke (ruling 7), and,
    /// with several sessions connected and none chosen, only once the designer
    /// has picked where the sketch goes (X26).
    var canSend: Bool { machine.canSend && !sessions.needsPick }

    /// A Claude Code session is there to take a sketch: one the Mac lists, or
    /// the one its status reports.
    var hasClaudeSession: Bool {
        !sessions.sessions.isEmpty || channel == .attached || channel == .existing
    }

    /// The session the next sketch goes to, when there is one to name.
    var targetSession: CanvasSessionEntry? { sessions.targetEntry }

    /// Claude Code has a permission dialog open at the Mac (X8). Nothing about
    /// the dialog itself crosses the wire; this is all the iPad is told.
    var waitingAtMac: Bool { sessions.targetEntry?.state == .waiting }

    /// The round "Waiting at the Mac" is about: the newest one of this device's
    /// that has no outcome yet. Nil when Claude Code is not waiting, or when
    /// it waits over something that is not one of this device's sketches.
    var waitingRoundID: String? {
        guard waitingAtMac else { return nil }
        return rounds.first { $0.status == .queued || $0.status == .sent }?.annotationId
    }

    /// Make `id` the target for the next sketch (X24). The Mac answers with a
    /// fresh `sessions`, which is what moves the tick: nothing is assumed here.
    func selectSession(_ id: String) {
        guard sessions.sessions.contains(where: { $0.id == id }), id != sessions.target else { return }
        send(CanvasWire.selectSession, SelectSessionMessage(id: id, t: nowMs()).json) { _ in }
    }

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

    /// The designer switched surface (B1). Choosing the blank page opens Draw
    /// Mode in the same tap: there is nothing on it to look at first, so the
    /// only thing to do there is draw. `pageViewport` is the blank page's own
    /// rect — the whole view — which the screen cannot read off its layout
    /// until the surface has actually changed.
    func chooseSurface(_ chosen: CanvasSurface, pageViewport: CanvasViewport) {
        preferredSurface = chosen
        guard chosen == .blank, surface == .blank, canEnterDrawMode else { return }
        enterDrawMode(viewport: pageViewport)
    }

    /// Freeze the picture and ask the Mac to keep the same frame (M1, D9).
    /// `viewport` is what the sketch will be sent with. There is no zoom rect
    /// to give: the designer can zoom while drawing, and a round is the whole
    /// frame whatever the zoom was (M5).
    ///
    /// On the blank surface there is no frame: nothing is frozen, nothing is
    /// asked of the Mac, and the sketch covers the whole page (B4).
    func enterDrawMode(viewport: CanvasViewport) {
        if surface == .blank {
            entryBase = .blank
            entryViewport = viewport
            notice = nil
            apply(.enterBlankDrawMode)
            return
        }
        entryBase = .mirror
        guard let frame = receiver.currentFrame() else {
            // Nothing has been displayed yet, so there is no frame to name and
            // no point freezing on it (M7's message, without the round trip).
            notice = .noFrame
            return
        }
        entryFrame = frame
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
    /// composites.
    func done(sketchPNG: Data) {
        // Only build and store the message when the machine will accept it.
        // Otherwise a Done the machine refuses — no strokes, or a round still
        // stranded in RETRY — would leave its payload behind as the thing the
        // next `hello` resends.
        guard canSend else { return }
        // A sketch too big for one frame would be refused by the framing,
        // which looks exactly like a link loss from here — so the round would
        // go to RETRY and be re-sent, identically, after every hello, for ever.
        // Refuse it here instead, where the designer still has the strokes and
        // can erase some of them (M10).
        guard sketchPNG.count <= CanvasWire.sketchMaxBytes else {
            notice = .sketchTooLarge
            return
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAnnotation = AnnotationMessage(sketchPNG: sketchPNG,
                                              viewport: entryViewport,
                                              note: trimmed.isEmpty ? nil : trimmed,
                                              t: nowMs(),
                                              base: entryBase,
                                              // X23: bound to the target as it is shown now.
                                              // Kept in the pending message, so a resend after
                                              // a link loss goes to the same session even if
                                              // the target has moved since.
                                              session: sessions.targetEntry?.id)
        apply(.done)
    }

    /// Leave without sending, keeping the strokes for the next entry (M6).
    func cancel() { apply(.cancel) }

    /// Leave without sending and throw the strokes away.
    func discard() { apply(.discard) }

    /// The iPad turned: the picture is laid out anew, so strokes drawn on the
    /// old layout no longer sit on what they were drawn over. The strokes stay
    /// in the canvas for the next entry (PRD G6).
    func rotated() { apply(.rotated) }

    /// The canvas emptied itself after `shouldClearStrokes`.
    func strokesCleared() { shouldClearStrokes = false }

    func dismissNotice() { notice = nil }

    func dismissReplyNotification() { replyNotification = nil }

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
        // to show both hops honestly rather than leave the last answer
        // standing. The next connection's hello and status repopulate them.
        channel = .none
        project = nil
        macName = nil
        sessions = .empty
        apply(.linkLost)
    }

    /// A Mac said hello. This is the resend trigger: the link is back up and a
    /// sketch stranded in RETRY goes out again.
    func macHelloReceived(name: String?) {
        objectWillChange.send()
        if macName != name { macName = name }
        apply(.helloReceived)
    }

    /// The Mac's channel state and the target's project (P1).
    func statusReceived(_ status: StatusMessage) {
        if channel != status.channel { channel = status.channel }
        if project != status.project { project = status.project }
    }

    /// A message from the Mac. Anything that does not parse is ignored, exactly
    /// as an unknown type is.
    func canvasMessage(type: String, object: [String: Any]) {
        switch type {
        case CanvasWire.status:
            guard let status = StatusMessage(json: object) else { return }
            statusReceived(status)
        case CanvasWire.frozen:
            guard let frozen = FrozenMessage(json: object), frozen.frame == freezeFrame else { return }
            apply(.frozen(ok: frozen.ok))
        case CanvasWire.rounds:
            guard let snapshot = RoundsMessage(json: object) else { return }
            let incoming = merged(snapshot: Array(snapshot.rounds.prefix(CanvasWire.roundsSnapshotLimit)))
            announceOutcomes(in: incoming)
            rounds = incoming
        case CanvasWire.agentReply:
            guard let reply = AgentReplyMessage(json: object) else { return }
            merge(reply)
        case CanvasWire.sessions:
            guard let message = SessionsMessage(json: object) else { return }
            if message != sessions { sessions = message }
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
        let frame = receiver.currentFrame() ?? entryFrame
        freezeFrame = frame
        send(CanvasWire.freeze, FreezeMessage(frame: frame, t: nowMs()).json) { _ in }
    }

    private func sendAnnotation() {
        guard let annotation = pendingAnnotation else { return }
        send(CanvasWire.annotation, annotation.json, attachment: annotation.sketchPNG) { [weak self] ok in
            // Main queue, by the receiver's contract.
            self?.apply(ok ? .sent : .linkLost)
        }
    }

    private func send(_ type: String, _ body: [String: Any], attachment: Data = Data(),
                      completion: @escaping (Bool) -> Void) {
        receiver.send(type, body, attachment: attachment, completion: completion)
    }

    // MARK: - Rounds

    /// The snapshot replaces the list — it is the Mac's authoritative set of
    /// the last 20 rounds for this device — but it may not move a round this
    /// device already knows *backwards* (M5). A snapshot is built when a hello
    /// arrives or the engine's rounds stream reconnects, so it can easily
    /// predate an `agentReply` that already landed here, and a round going from
    /// "applied, with a message" back to "queued" reads as the work having been
    /// undone.
    private func merged(snapshot incoming: [CanvasRound]) -> [CanvasRound] {
        guard !rounds.isEmpty else { return incoming }
        let known = Dictionary(rounds.map { ($0.annotationId, $0) }, uniquingKeysWith: { first, _ in first })
        return incoming.map { round in
            guard let local = known[round.annotationId],
                  local.status.progressRank > round.status.progressRank else { return round }
            var kept = round
            kept.status = local.status
            // A `queued`/`sent` entry carries no outcome text, so keep what the
            // reply already delivered. Everything else (the note, createdAt) is
            // the snapshot's to state.
            if kept.message == nil { kept.message = local.message }
            if kept.prUrl == nil { kept.prUrl = local.prUrl }
            return kept
        }
    }

    /// A snapshot can be the first this device hears of an outcome: the reply
    /// landed while the link was down. Announce the newest round that was
    /// still in flight here and has an outcome there. Rounds this device never
    /// saw in flight are history, not news, so a first snapshot announces
    /// nothing.
    private func announceOutcomes(in incoming: [CanvasRound]) {
        let known = Dictionary(rounds.map { ($0.annotationId, $0.status) }, uniquingKeysWith: { first, _ in first })
        let finished = incoming.first { round in
            guard let before = known[round.annotationId] else { return false }
            return before.progressRank < round.status.progressRank
        }
        if let finished, let notification = ReplyNotification(round: finished) {
            lastAnnounced = notification
            replyNotification = notification
        }
    }

    /// A live status change (ruling 4). It updates the round it names, or — if
    /// this device has no snapshot of that round — becomes one at the front.
    private func merge(_ reply: AgentReplyMessage) {
        defer {
            // A reply that changes nothing — the same outcome relayed twice —
            // must not bring back a card the designer already dismissed.
            if let round = rounds.first(where: { $0.annotationId == reply.annotationId }),
               round.status == reply.status,
               let notification = ReplyNotification(round: round),
               notification != lastAnnounced {
                lastAnnounced = notification
                replyNotification = notification
            }
        }
        if let index = rounds.firstIndex(where: { $0.annotationId == reply.annotationId }) {
            var round = rounds[index]
            // Forward only, for the same reason a snapshot is (M5): these two
            // arrive from one relay but are generated by different events.
            if reply.status.progressRank >= round.status.progressRank {
                round.status = reply.status
            }
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
