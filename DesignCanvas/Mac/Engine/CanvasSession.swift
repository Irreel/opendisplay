import CoreGraphics
import CoreVideo
import Dispatch
import Foundation

/// Where a canvas session sends its messages: the link to its iPad.
/// `MirrorLink` conforms.
///
/// Delivery is best-effort. Whether the link is up is knowable only on the
/// link's own queue, so a send hands the message over and returns; one that
/// finds the link down there is dropped with a log line. The Bool is the
/// synchronous answer only: false means the message could not be framed at
/// all (not serialisable, or over the wire's size limits).
protocol CanvasOutbound: AnyObject {
    @discardableResult func send(_ type: String, _ object: [String: Any], attachment: Data) -> Bool
}

extension CanvasOutbound {
    @discardableResult func send(_ type: String, _ object: [String: Any]) -> Bool {
        send(type, object, attachment: Data())
    }
}

/// What every session tells its iPad about the Claude Code hop (P1), written
/// by the app as the daemon health poll and the session list change, plus the
/// one fact that flows the other way: when the last frame was captured, which
/// is how the app knows capture is running (`isCapturing`). Thread-safe:
/// sessions and the capture read and stamp it off the main queue while the
/// app writes and reads it on the main one.
final class CanvasStatus {
    private let lock = NSLock()
    private var storedChannelState: ChannelState = .none
    private var storedLastFrameAt: Date?
    private var storedSessions: SessionsMessage = .empty

    init() {}

    var channelState: ChannelState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedChannelState
        }
        set {
            lock.lock()
            storedChannelState = newValue
            lock.unlock()
        }
    }

    /// The connected Claude Code sessions as last heard from the daemon. Written
    /// by `CanvasHub`, read by each session when its iPad says hello.
    var sessions: SessionsMessage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedSessions
        }
        set {
            lock.lock()
            storedSessions = newValue
            lock.unlock()
        }
    }

    /// The `status` message every iPad is sent. The project it names is where
    /// the next sketch goes: the target session's folder, absent when there is
    /// no target (XG8).
    var statusMessage: StatusMessage {
        lock.lock()
        defer { lock.unlock() }
        return StatusMessage(channel: storedChannelState, project: storedSessions.targetEntry?.folder)
    }

    /// A frame was captured at `at`. Called at capture rate from the stream queue.
    func noteFrame(at: Date) {
        lock.lock()
        storedLastFrameAt = at
        lock.unlock()
    }

    /// Frames are flowing: one arrived within the last `window` seconds. This is the ground
    /// truth behind the menu's Screen Recording row — a permission preflight that says no
    /// while this says yes is the preflight being wrong (seen on macOS 26, 2026-09-30).
    func isCapturing(now: Date, window: TimeInterval = 2) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = storedLastFrameAt else { return false }
        return now.timeIntervalSince(last) < window
    }
}

/// One iPad's join between the wire and the local daemon: it answers `freeze`
/// from the Mac's frame ring, composites the sketch an `annotation` carries
/// onto the frozen frame, uploads the round, and relays what Claude Code said
/// back to the device (spec sections 3 and 5.4).
///
/// One per iPad (install id) for the app's life, not one per connection. A
/// link drop in SENDING is answered by the iPad re-sending the same
/// `annotation` after the next hello (plan ruling 5), and the frame that
/// sketch belongs to, and the `t` that identifies the round, are simply still
/// here when it does.
///
/// Threading. Messages arrive on the stream queue and return without doing PNG
/// work, compositing or I/O: all of that happens in `UploadPipeline`, which
/// owns the queue of accepted uploads. `deliver`, `sendSessions` and
/// `sendStatus` may be called from anywhere. All mutable state is behind `lock`.
final class CanvasSession {

    let installID: String

    private let daemon: DaemonAPI
    private let status: CanvasStatus
    private let frames: CleanFrameSource
    private let now: () -> Date
    private let pipeline: UploadPipeline

    private let lock = NSLock()
    /// Weak: the link owns its connection and outlives this attachment only as
    /// long as the engine keeps it.
    private weak var outbound: CanvasOutbound?
    private var heldCapture: (capture: UploadPipeline.FreezeCapture, at: Date)?
    /// The `t` of the last `annotation` accepted. The iPad re-sends identical
    /// bytes after a link loss, so `t` identifies the round.
    private var lastAcceptedT: Double?
    /// What this attachment was last told, so a status that did not change is
    /// not sent again.
    private var lastSentStatus: StatusMessage?

    /// How long a frozen frame stays usable. A full-resolution `CGImage` is
    /// megabytes, and a device that never comes back must not pin one for the
    /// app's whole life.
    static let heldCaptureExpiry: TimeInterval = 600

    init(
        installID: String,
        deviceName: String,
        daemon: DaemonAPI,
        status: CanvasStatus,
        frames: CleanFrameSource,
        workQueue: DispatchQueue = DispatchQueue(label: "canvas.work", qos: .utility),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.installID = installID
        self.daemon = daemon
        self.status = status
        self.frames = frames
        self.now = now
        self.pipeline = UploadPipeline(
            deviceName: deviceName,
            daemon: daemon,
            workQueue: workQueue,
            sleep: sleep
        )
    }

    /// Annotations accepted but not yet uploaded or dropped.
    var pendingUploadCount: Int { pipeline.pendingUploadCount }

    // MARK: - The link

    /// The iPad said hello on `outbound`. It keeps no round history of its own,
    /// so the snapshot is what shows a reply that landed while it was away
    /// (spec section 5.4); the session list and the status follow.
    func attach(_ outbound: CanvasOutbound) {
        lock.lock()
        self.outbound = outbound
        lastSentStatus = nil
        lock.unlock()

        sendRoundsSnapshot(via: outbound)
        outbound.send(CanvasWire.sessions, status.sessions.json)
        sendStatus()
    }

    /// The link that said hello is gone. Only the link is forgotten: queued
    /// uploads, the held freeze capture and the last accepted round all stay,
    /// because the next hello may be the iPad coming back to finish the round.
    func detach(_ outbound: CanvasOutbound) {
        lock.lock()
        if self.outbound === outbound { self.outbound = nil }
        lock.unlock()
    }

    private var currentOutbound: CanvasOutbound? {
        lock.lock()
        defer { lock.unlock() }
        return outbound
    }

    // MARK: - Mac to iPad

    /// The session list changed (or the target did). `CanvasHub` calls this for
    /// every session; one with no link has nowhere to send it, and its next
    /// hello sends the list anyway.
    func sendSessions() {
        currentOutbound?.send(CanvasWire.sessions, status.sessions.json)
    }

    /// The channel state or the target's project may have changed. Sent only
    /// when what the iPad was last told is different.
    func sendStatus() {
        let message = status.statusMessage
        lock.lock()
        guard let outbound, message != lastSentStatus else {
            lock.unlock()
            return
        }
        lastSentStatus = message
        lock.unlock()
        outbound.send(CanvasWire.status, message.json)
    }

    /// The same snapshot hello sends, on demand. `CanvasHub` calls this after
    /// the daemon's rounds stream (re)connects: the daemon replays nothing, so
    /// a `round.updated` emitted while the stream was down is only ever seen
    /// again in a snapshot (I2).
    func resendSnapshot() {
        guard let outbound = currentOutbound else { return }
        sendRoundsSnapshot(via: outbound)
    }

    /// A daemon that cannot answer still gets an empty snapshot out, so the
    /// device is not left waiting on one.
    private func sendRoundsSnapshot(via outbound: CanvasOutbound) {
        let daemon = self.daemon
        let deviceID = installID
        Task {
            let rounds: [CanvasRound]
            do {
                rounds = try await daemon.rounds(deviceID: deviceID, limit: CanvasWire.roundsSnapshotLimit)
            } catch {
                Log.info("canvas: rounds snapshot fetch failed (\(error)); sending an empty one")
                rounds = []
            }
            let snapshot = RoundsMessage(rounds: Array(rounds.prefix(CanvasWire.roundsSnapshotLimit)).map { round in
                var capped = round
                capped.message = round.message?.truncatedUTF8(maxBytes: CanvasWire.replyMessageMaxBytes)
                return capped
            })
            outbound.send(CanvasWire.rounds, snapshot.json)
        }
    }

    /// Relays one round update to the device it belongs to. A drop on the
    /// floor here (another device's round, or no link) is deliberate: the
    /// snapshot the next hello sends carries the round anyway.
    func deliver(_ update: RoundUpdate) {
        guard update.deviceID == installID, let outbound = currentOutbound else { return }
        let reply = AgentReplyMessage(
            annotationId: update.round.annotationId,
            status: update.round.status,
            message: update.round.message?.truncatedUTF8(maxBytes: CanvasWire.replyMessageMaxBytes),
            prUrl: update.round.prUrl,
            t: (now().timeIntervalSince1970 * 1000).rounded()
        )
        outbound.send(CanvasWire.agentReply, reply.json)
    }

    // MARK: - iPad to Mac

    func receive(type: String, object: [String: Any], attachment: Data) {
        switch type {
        case CanvasWire.freeze:
            handleFreeze(object)
        case CanvasWire.annotation:
            handleAnnotation(object, attachment: attachment)
        case CanvasWire.selectSession:
            handleSelectSession(object)
        default:
            break
        }
    }

    /// The iPad picked the target (X24). The daemon owns the target, so the
    /// choice goes there; the list that comes back on the sessions stream is
    /// what tells this iPad, and every other one, that it took.
    private func handleSelectSession(_ object: [String: Any]) {
        guard let message = SelectSessionMessage(json: object) else {
            Log.info("canvas: unparseable selectSession")
            return
        }
        let daemon = self.daemon
        Task {
            do {
                try await daemon.setTarget(instance: message.id, fromIPad: true)
            } catch {
                Log.info("canvas: selectSession failed (\(error))")
            }
        }
    }

    // MARK: - freeze

    /// Answers `frozen` before any PNG work happens, because the iPad's Draw
    /// Mode is blocked in FREEZING until it arrives (spec section 3). A frame
    /// that is in the ring but cannot be turned into an image is a miss: the
    /// user must not be left drawing on a frame this Mac cannot use.
    private func handleFreeze(_ object: [String: Any]) {
        guard let outbound = currentOutbound else { return }
        guard let message = FreezeMessage(json: object) else {
            Log.info("canvas: unparseable freeze")
            return
        }
        guard let found = frames.cleanFrame(message.frame),
              let image = Compositor.cgImage(from: found.pixelBuffer) else {
            Log.info("canvas: freeze missed the ring at frame \(message.frame)")
            outbound.send(CanvasWire.frozen, FrozenMessage(frame: message.frame, ok: false).json)
            return
        }

        outbound.send(CanvasWire.frozen, FrozenMessage(frame: message.frame, ok: true).json)

        // Stamped with the frame's own capture time, so the store and the
        // channel's "Captured at" describe the moment the designer froze (M2).
        let capture = UploadPipeline.FreezeCapture(image: image, capturedAt: found.capturedAt)
        lock.lock()
        let hadPrevious = heldCapture != nil
        heldCapture = (capture, now())
        lock.unlock()
        pipeline.enqueue(capture: capture)

        if hadPrevious {
            Log.info("canvas: discarding previous freeze capture")
        }
        Log.info("canvas: freeze accepted at frame \(message.frame)")
    }

    // MARK: - annotation

    /// Hands the freeze capture and the sketch to the upload pipeline and
    /// returns: the composite and the upload are the pipeline's work, not the
    /// stream queue's. `createdAt` is stamped here rather than when the upload
    /// finally lands, so retries keep their original order in the store.
    ///
    /// A `t` already accepted is the iPad's re-send arriving after the Mac had
    /// in fact taken the round: it is acknowledged by being dropped, never
    /// uploaded twice.
    private func handleAnnotation(_ object: [String: Any], attachment: Data) {
        guard let message = AnnotationMessage(json: object, attachment: attachment) else {
            Log.info("canvas: unparseable annotation")
            return
        }
        let createdAt = now()
        // Drawn on the iPad's blank page: no `freeze` came first and no frame
        // is involved. A held capture belongs to a mirror sketch that may
        // still arrive, so it is left exactly where it is.
        var blankPage: (width: Int, height: Int)?
        if message.base == .blank {
            guard let page = Self.blankPageSize(for: message.viewport) else {
                Log.info("canvas: dropping blank annotation — viewport \(message.viewport.width)x\(message.viewport.height)@\(message.viewport.scale) has no area")
                return
            }
            blankPage = page
        }

        lock.lock()
        if lastAcceptedT == message.t {
            lock.unlock()
            Log.info("canvas: annotation t=\(message.t) was already accepted — dropping the re-send")
            return
        }
        let base: UploadPipeline.Base
        if let blankPage {
            base = .blank(width: blankPage.width, height: blankPage.height)
        } else {
            guard let held = heldCapture, createdAt.timeIntervalSince(held.at) <= Self.heldCaptureExpiry else {
                heldCapture = nil
                lock.unlock()
                Log.info("canvas: dropping annotation — no freeze capture is held")
                return
            }
            heldCapture = nil
            base = .frame(held.capture)
        }
        lastAcceptedT = message.t
        lock.unlock()

        pipeline.enqueue(annotation: UploadPipeline.AnnotationJob(
            base: base,
            sketchPNG: message.sketchPNG,
            zoomRect: .full,
            viewport: message.viewport,
            note: message.note,
            deviceID: installID,
            createdAt: createdAt,
            session: message.session
        ))

        Log.info("canvas: annotation queued (\(message.sketchPNG.count)-byte sketch\(message.base == .blank ? ", blank page" : ""))")
    }

    /// The most pixels a blank page may have on one side. Above any iPad's
    /// panel; it only stops a nonsense viewport from asking for a huge bitmap.
    static let blankPageMaxSide = 4096

    /// The blank page for a sketch drawn at `viewport`: the sketch surface's
    /// own pixel size (`w * scale` by `h * scale`), so the sketch lands on it
    /// one-to-one. Nil when the viewport has no area.
    static func blankPageSize(for viewport: CanvasViewport) -> (width: Int, height: Int)? {
        guard viewport.width > 0, viewport.height > 0, viewport.scale > 0, viewport.scale.isFinite else { return nil }
        let width = (Double(viewport.width) * viewport.scale).rounded()
        let height = (Double(viewport.height) * viewport.scale).rounded()
        return (max(1, Int(min(width, Double(blankPageMaxSide)))),
                max(1, Int(min(height, Double(blankPageMaxSide)))))
    }
}
