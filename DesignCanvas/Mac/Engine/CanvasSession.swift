import CoreGraphics
import CoreVideo
import Dispatch
import Foundation

/// The two additive `ping` fields (spec section 2, P1), shared by every
/// session and written by the app as the daemon health poll and the project
/// picker change, plus the one fact that flows the other way: when the last
/// captured frame arrived, which is how the app knows capture is running
/// (`isCapturing`). Thread-safe because sessions read and stamp it from the
/// sender's queue while the app writes and reads it from the main one.
final class CanvasStatus {
    private let lock = NSLock()
    private var storedChannelState: ChannelState = .none
    private var storedProjectName: String?
    private var storedLastFrameAt: Date?

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

    var projectName: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedProjectName
        }
        set {
            lock.lock()
            storedProjectName = newValue
            lock.unlock()
        }
    }

    /// `channel` always; `project` only when a project is selected — an
    /// absent key is how the iPad is told there is none (spec section 2).
    var pingFields: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        // `blank` is a capability, not a state: this Mac composites a sketch
        // drawn on the iPad's blank page, and says so on every beat so the
        // iPad offers that page only to a Mac that can take it.
        var fields = [
            CanvasWire.pingChannelKey: storedChannelState.rawValue,
            CanvasWire.pingBlankKey: "1",
        ]
        if let storedProjectName {
            fields[CanvasWire.pingProjectKey] = storedProjectName
        }
        return fields
    }

    /// A frame was captured at `at`. Called at capture rate from the sender's queue.
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

/// One connected iPad's join between the OpenDisplay wire and the local
/// daemon: it rings the captured frames, answers `freeze` from that ring,
/// composites the sketch an `annotation` carries onto the frozen frame,
/// uploads the round, and relays what Claude Code said back to the device
/// (spec sections 3 and 5.4).
///
/// Threading. Every `SenderCanvasDelegate` callback arrives on the sender's
/// serial queue and returns without doing PNG work, compositing or I/O: all
/// of that happens in `UploadPipeline`, which also owns the queue of accepted
/// uploads and outlives this session when it has to. `deliver` may be called
/// from anywhere (`CanvasHub`'s consuming task). All of this session's own
/// mutable state is behind `lock`.
final class CanvasSession: SenderCanvasDelegate {

    private let daemon: DaemonAPI
    private let status: CanvasStatus
    private let now: () -> Date
    private let pipeline: UploadPipeline
    /// Shared with every other session the hub built, so a frozen frame and a
    /// round's identity survive the session that first saw them (C1).
    private let parking: CanvasCaptureParkingLot

    private let lock = NSLock()
    private var ring = FrameRing()
    private var peer: CanvasPeer?
    /// Weak: this is the `MacSender` that owns the link, and it must not be
    /// kept alive by the session it hands its messages to.
    private weak var outbound: CanvasOutbound?
    private var heldCapture: UploadPipeline.FreezeCapture?

    /// `parking` defaults to a private lot so a session is constructible
    /// without a hub (tests, and any future single-session caller): it then
    /// only ever finds what it parked itself, which is the old in-session
    /// behaviour.
    init(
        deviceName: String,
        daemon: DaemonAPI,
        status: CanvasStatus,
        parking: CanvasCaptureParkingLot = CanvasCaptureParkingLot(),
        workQueue: DispatchQueue = DispatchQueue(label: "canvas.work", qos: .utility),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.daemon = daemon
        self.status = status
        self.parking = parking
        self.now = now
        self.pipeline = UploadPipeline(
            deviceName: deviceName,
            daemon: daemon,
            workQueue: workQueue,
            sleep: sleep
        )
    }

    /// Ending a session does not cancel the rounds it accepted: the device was
    /// told they were sent, so the pipeline keeps them and keeps trying. Said
    /// out loud, because otherwise a round landing minutes after its iPad
    /// disconnected reads like the work of a session that is not there.
    deinit {
        let pending = pipeline.pendingUploadCount
        if pending > 0 {
            Log.info("canvas: session ended with \(pending) uploads pending; continuing in the background")
        }
    }

    /// Annotations accepted but not yet uploaded or dropped.
    var pendingUploadCount: Int { pipeline.pendingUploadCount }

    // MARK: - SenderCanvasDelegate

    /// Every hello, including the re-hellos a rotation causes: the iPad keeps
    /// no round history of its own, so the snapshot is what shows a reply
    /// that landed while it was away (spec section 5.4).
    func canvasPeerDidHello(_ peer: CanvasPeer, outbound: CanvasOutbound) {
        lock.lock()
        self.peer = peer
        self.outbound = outbound
        lock.unlock()

        sendRoundsSnapshot(deviceID: peer.installID, via: outbound)
    }

    /// The same snapshot hello sends, on demand. `CanvasHub` calls this after
    /// the daemon's rounds stream (re)connects: the daemon replays nothing, so
    /// a `round.updated` emitted while the stream was down is only ever seen
    /// again in a snapshot (I2). A session with no device or no link has
    /// nothing to send and nowhere to send it.
    func resendSnapshot() {
        lock.lock()
        let deviceID = peer?.installID
        let outbound = self.outbound
        lock.unlock()

        guard let deviceID, let outbound else { return }
        sendRoundsSnapshot(deviceID: deviceID, via: outbound)
    }

    /// A daemon that cannot answer still gets an empty snapshot out, so the
    /// device is not left waiting on one.
    private func sendRoundsSnapshot(deviceID: String, via outbound: CanvasOutbound) {
        let daemon = self.daemon
        Task {
            let rounds: [CanvasRound]
            do {
                rounds = try await daemon.rounds(deviceID: deviceID, limit: CanvasWire.roundsSnapshotLimit)
            } catch {
                Log.info("canvas: rounds snapshot fetch failed (\(error)); sending an empty one")
                rounds = []
            }
            outbound.sendCanvasJSONData(CanvasSession.roundsPayload(RoundsMessage(rounds: rounds)))
        }
    }

    /// Relays one round update to the device it belongs to. A drop on the
    /// floor here (wrong device, or no link) is deliberate: the snapshot the
    /// next hello sends carries the round anyway.
    func deliver(_ update: RoundUpdate) {
        lock.lock()
        let installID = peer?.installID
        let outbound = self.outbound
        lock.unlock()

        guard let outbound, installID == update.deviceID else { return }

        let reply = AgentReplyMessage(
            annotationId: update.round.annotationId,
            status: update.round.status,
            message: update.round.message?.truncatedUTF8(maxBytes: CanvasWire.replyMessageMaxBytes),
            prUrl: update.round.prUrl,
            t: (now().timeIntervalSince1970 * 1000).rounded()
        )
        send(type: CanvasWire.agentReply, reply.json, via: outbound)
    }

    /// Runs at capture rate: one deep copy into the ring and nothing else —
    /// no logging, no I/O (global constraint "logging discipline").
    func canvasDidEncodeFrame(_ pixelBuffer: CVPixelBuffer, captureMs: Int64) {
        lock.lock()
        ring.append(pixelBuffer, captureMs: captureMs)
        lock.unlock()
        status.noteFrame(at: Date())
    }

    func canvasDidReceive(type: String, object: [String: Any], outbound: CanvasOutbound) {
        switch type {
        case CanvasWire.freeze:
            handleFreeze(object, outbound: outbound)
        case CanvasWire.annotation:
            handleAnnotation(object)
        default:
            break
        }
    }

    /// Idempotent, because one drop can be reported more than once.
    ///
    /// Only the link is forgotten. Queued uploads, the ring and — since C1 —
    /// the held freeze capture all stay: the round the designer already
    /// pressed Done on must still reach Claude Code; the next hello freezes
    /// against the same frames; and a drop in SENDING is answered by the iPad
    /// re-sending the same `annotation` after the next `hello` (ruling 5), so
    /// the frame that sketch belongs to has to still be there — here if the
    /// session survives, in the parking lot if it does not.
    func canvasLinkDidDrop() {
        lock.lock()
        outbound = nil
        lock.unlock()
    }

    func canvasPingFields() -> [String: String] { status.pingFields }

    // MARK: - freeze

    /// Answers `frozen` before any PNG work happens, because the iPad's Draw
    /// Mode is blocked in FREEZING until it arrives (spec section 3). A frame
    /// that is in the ring but cannot be turned into an image is a miss: the
    /// user must not be left drawing on a frame this Mac cannot use.
    private func handleFreeze(_ object: [String: Any], outbound: CanvasOutbound) {
        guard let message = FreezeMessage(json: object) else {
            Log.info("canvas: unparseable freeze")
            send(type: CanvasWire.frozen, FrozenMessage(ok: false).json, via: outbound)
            return
        }

        lock.lock()
        let found = ring.frame(at: message.captureMs)
        lock.unlock()

        guard let found, let image = Compositor.cgImage(from: found.pixelBuffer) else {
            Log.info("canvas: freeze missed the ring at captureMs \(message.captureMs)")
            send(type: CanvasWire.frozen, FrozenMessage(ok: false).json, via: outbound)
            return
        }

        send(type: CanvasWire.frozen, FrozenMessage(ok: true).json, via: outbound)

        // Stamped with the frame's own millisecond — the same clock the video
        // telemetry's `cap` uses, which is Unix epoch ms — so the store and the
        // channel's "Captured at" describe the moment the designer froze (M2).
        let capture = UploadPipeline.FreezeCapture(
            image: image,
            capturedAt: Date(timeIntervalSince1970: Double(found.captureMs) / 1000)
        )
        lock.lock()
        let hadPrevious = heldCapture != nil
        heldCapture = capture
        let installID = peer?.installID
        lock.unlock()
        // Parked as well as held, so the session that serves the reconnect
        // after a link drop inherits it. A new freeze from this device
        // replaces whatever was parked: the designer has moved on.
        if let installID {
            parking.park(capture, installID: installID, at: now())
        }
        pipeline.enqueue(capture: capture)

        if hadPrevious {
            Log.info("canvas: discarding previous freeze capture")
        }
        Log.info("canvas: freeze accepted at captureMs \(found.captureMs)")
    }

    // MARK: - annotation

    /// Hands the freeze capture and the sketch to the upload pipeline and
    /// returns: the composite and the upload are the pipeline's work, not the
    /// sender queue's. `createdAt` is stamped here rather than when the upload
    /// finally lands, so retries keep their original order in the store.
    ///
    /// The capture is this session's held one, or — after a link drop rebuilt
    /// the session under the iPad's re-send — the one parked for this device
    /// (C1). A `t` already accepted from this device is that re-send arriving
    /// after the Mac had in fact taken the round: it is acknowledged by being
    /// dropped, never uploaded twice.
    private func handleAnnotation(_ object: [String: Any]) {
        guard let message = AnnotationMessage(json: object) else {
            Log.info("canvas: unparseable annotation")
            return
        }
        let createdAt = now()

        lock.lock()
        guard let installID = peer?.installID else {
            lock.unlock()
            Log.info("canvas: dropping annotation — no peer has said hello yet")
            return
        }
        lock.unlock()

        guard !parking.hasAccepted(t: message.t, installID: installID) else {
            Log.info("canvas: annotation t=\(message.t) was already accepted — dropping the re-send")
            return
        }

        let base: UploadPipeline.Base
        if message.base == .blank {
            // Drawn on the iPad's blank page: no `freeze` came first and no
            // frame is involved. A held or parked capture belongs to a mirror
            // sketch that may still arrive, so it is left exactly where it is.
            guard let page = Self.blankPageSize(for: message.viewport) else {
                Log.info("canvas: dropping blank annotation — viewport \(message.viewport.width)x\(message.viewport.height)@\(message.viewport.scale) has no area")
                return
            }
            base = .blank(width: page.width, height: page.height)
        } else {
            lock.lock()
            let held = heldCapture
            heldCapture = nil
            lock.unlock()

            guard let capture = held ?? parking.parkedCapture(installID: installID, now: createdAt) else {
                Log.info("canvas: dropping annotation — no freeze capture is held")
                return
            }
            parking.removeParkedCapture(installID: installID)
            base = .frame(capture)
        }
        parking.recordAccepted(t: message.t, installID: installID)

        pipeline.enqueue(annotation: UploadPipeline.AnnotationJob(
            base: base,
            sketchPNG: message.sketchPNG,
            zoomRect: message.zoomRect,
            viewport: message.viewport,
            note: message.note,
            deviceID: installID,
            createdAt: createdAt
        ))

        Log.info("canvas: annotation queued (\(message.sketchPNG.count)-byte sketch\(message.base == .blank ? ", blank page" : ""))")
    }

    /// The most pixels a blank page may have on one side. Above any iPad's
    /// panel; it only stops a nonsense viewport from asking for a huge bitmap.
    static let blankPageMaxSide = 4096

    /// The blank page for a sketch drawn at `viewport`: the sketch surface's
    /// own pixel size (`w * scale` by `h * scale`, PROTOCOL.md 11.2), so the
    /// sketch lands on it one-to-one. Nil when the viewport has no area.
    static func blankPageSize(for viewport: CanvasViewport) -> (width: Int, height: Int)? {
        guard viewport.width > 0, viewport.height > 0, viewport.scale > 0, viewport.scale.isFinite else { return nil }
        let width = (Double(viewport.width) * viewport.scale).rounded()
        let height = (Double(viewport.height) * viewport.scale).rounded()
        return (max(1, Int(min(width, Double(blankPageMaxSide)))),
                max(1, Int(min(height, Double(blankPageMaxSide)))))
    }

    // MARK: - sending

    private func send(type: String, _ body: [String: Any], via outbound: CanvasOutbound) {
        var object = body
        object["type"] = type
        outbound.sendCanvasJSON(object)
    }

    /// `RoundsMessage.encoded` is the only thing that knows how to shrink a
    /// snapshot under the 32768-byte wire limit (ruling 3), and it produces
    /// `{"rounds":[…]}`. The control type is spliced in after the opening
    /// brace rather than re-encoded, so that shrinking is not undone; the
    /// budget handed to `encoded` is reduced by exactly what the splice adds.
    private static func roundsPayload(_ message: RoundsMessage) -> Data {
        let prefix = Data("{\"type\":\"\(CanvasWire.rounds)\",".utf8)
        let added = prefix.count - 1   // the prefix replaces the leading `{`
        var payload = prefix
        payload.append(message.encoded(limit: CanvasWire.senderJSONLimit - added).dropFirst())
        return payload
    }
}
