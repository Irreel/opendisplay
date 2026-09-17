import CoreGraphics
import CoreVideo
import Dispatch
import Foundation

/// The two additive `ping` fields (spec section 2, P1), shared by every
/// session and written by the app as the daemon health poll and the project
/// picker change. Thread-safe because sessions read it from the sender's
/// queue while the app writes it from the main one.
final class CanvasStatus {
    private let lock = NSLock()
    private var storedChannelState: ChannelState = .none
    private var storedProjectName: String?

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
        var fields = [CanvasWire.pingChannelKey: storedChannelState.rawValue]
        if let storedProjectName {
            fields[CanvasWire.pingProjectKey] = storedProjectName
        }
        return fields
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

    private let lock = NSLock()
    private var ring = FrameRing()
    private var peer: CanvasPeer?
    /// Weak: this is the `MacSender` that owns the link, and it must not be
    /// kept alive by the session it hands its messages to.
    private weak var outbound: CanvasOutbound?
    private var heldCapture: UploadPipeline.FreezeCapture?

    init(
        deviceName: String,
        daemon: DaemonAPI,
        status: CanvasStatus,
        workQueue: DispatchQueue = DispatchQueue(label: "canvas.work", qos: .utility),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.daemon = daemon
        self.status = status
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
    /// that landed while it was away (spec section 5.4). A daemon that cannot
    /// answer still gets an empty snapshot out, so the device is not left
    /// waiting on one.
    func canvasPeerDidHello(_ peer: CanvasPeer, outbound: CanvasOutbound) {
        lock.lock()
        self.peer = peer
        self.outbound = outbound
        lock.unlock()

        let daemon = self.daemon
        let deviceID = peer.installID
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

    /// Idempotent, because one drop can be reported more than once. Queued
    /// uploads and the ring stay: the round the designer already pressed Done
    /// on must still reach Claude Code, and the next hello freezes against the
    /// same frames.
    func canvasLinkDidDrop() {
        lock.lock()
        outbound = nil
        let hadCapture = heldCapture != nil
        heldCapture = nil
        lock.unlock()

        if hadCapture {
            Log.info("canvas: link dropped — discarding the held freeze capture")
        }
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

        let capture = UploadPipeline.FreezeCapture(image: image)
        lock.lock()
        let hadPrevious = heldCapture != nil
        heldCapture = capture
        lock.unlock()
        pipeline.enqueue(capture: capture)

        if hadPrevious {
            Log.info("canvas: discarding previous freeze capture")
        }
        Log.info("canvas: freeze accepted at captureMs \(found.captureMs)")
    }

    // MARK: - annotation

    /// Hands the held freeze capture and the sketch to the upload pipeline
    /// and returns: the composite and the upload are the pipeline's work, not
    /// the sender queue's. `createdAt` is stamped here rather than when the
    /// upload finally lands, so retries keep their original order in the
    /// store.
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
        guard let capture = heldCapture else {
            lock.unlock()
            Log.info("canvas: dropping annotation — no freeze capture is held")
            return
        }
        heldCapture = nil
        lock.unlock()

        pipeline.enqueue(annotation: UploadPipeline.AnnotationJob(
            capture: capture,
            sketchPNG: message.sketchPNG,
            zoomRect: message.zoomRect,
            viewport: message.viewport,
            note: message.note,
            deviceID: installID,
            createdAt: createdAt
        ))

        Log.info("canvas: annotation queued (\(message.sketchPNG.count)-byte sketch)")
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
