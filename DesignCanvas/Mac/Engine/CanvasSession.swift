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
/// of that happens on `workQueue` and in the upload pipeline below. `deliver`
/// may be called from anywhere (`CanvasHub`'s consuming task). All mutable
/// state is behind `lock`, with the one documented exception of
/// `FreezeCapture.captureID`, which only the (serial) upload pipeline touches.
final class CanvasSession: SenderCanvasDelegate {

    /// A frozen frame waiting for its sketch. A reference type because the
    /// capture post and the annotation job that needs its id are two
    /// different pipeline jobs.
    private final class FreezeCapture {
        let image: CGImage
        let width: Int
        let height: Int
        /// Set by the capture job, read (and cleared, on `.captureNotFound`)
        /// by the annotation job. Both run on the upload pipeline, which is
        /// serial, so this needs no lock of its own.
        var captureID: String?

        init(image: CGImage) {
            self.image = image
            self.width = image.width
            self.height = image.height
        }
    }

    /// Everything an `annotation` needs after the sender's queue is released.
    private struct AnnotationJob {
        let capture: FreezeCapture
        let sketchPNG: Data
        let zoomRect: NormalizedRect
        let viewport: CanvasViewport
        let note: String?
        let deviceID: String
        let createdAt: Date
    }

    private enum UploadJob {
        case capture(FreezeCapture)
        case annotation(AnnotationJob)
    }

    private let deviceName: String
    private let daemon: DaemonAPI
    private let status: CanvasStatus
    private let workQueue: DispatchQueue
    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void

    private let lock = NSLock()
    private var ring = FrameRing()
    private var peer: CanvasPeer?
    /// Weak: this is the `MacSender` that owns the link, and it must not be
    /// kept alive by the session it hands its messages to.
    private weak var outbound: CanvasOutbound?
    private var heldCapture: FreezeCapture?
    private var jobs: [UploadJob] = []
    private var draining = false
    private var pendingUploads = 0

    init(
        deviceName: String,
        daemon: DaemonAPI,
        status: CanvasStatus,
        workQueue: DispatchQueue = DispatchQueue(label: "canvas.work", qos: .utility),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.deviceName = deviceName
        self.daemon = daemon
        self.status = status
        self.workQueue = workQueue
        self.now = now
        self.sleep = sleep
    }

    /// Annotations accepted but not yet uploaded or dropped.
    var pendingUploadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingUploads
    }

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

        let capture = FreezeCapture(image: image)
        lock.lock()
        let hadPrevious = heldCapture != nil
        heldCapture = capture
        enqueueLocked(.capture(capture))
        lock.unlock()

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
        enqueueLocked(.annotation(AnnotationJob(
            capture: capture,
            sketchPNG: message.sketchPNG,
            zoomRect: message.zoomRect,
            viewport: message.viewport,
            note: message.note,
            deviceID: installID,
            createdAt: createdAt
        )))
        lock.unlock()

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

    // MARK: - upload pipeline

    /// Appends a job and, when nothing is draining yet, starts the one task
    /// that runs them. Caller holds `lock`.
    private func enqueueLocked(_ job: UploadJob) {
        jobs.append(job)
        if case .annotation = job {
            pendingUploads += 1
        }
        guard !draining else { return }
        draining = true
        startDraining()
    }

    private func dequeue() -> UploadJob? {
        lock.lock()
        defer { lock.unlock() }
        guard !jobs.isEmpty else {
            draining = false
            return nil
        }
        return jobs.removeFirst()
    }

    private func finishAnnotationJob() {
        lock.lock()
        pendingUploads -= 1
        lock.unlock()
    }

    /// The upload pipeline: one task, one job at a time, strictly in order.
    ///
    /// It holds the session only for the moment it takes to pull the next job
    /// (and, for an annotation, to mark it finished). The job runners are
    /// static and take everything they need by value, so a job that is
    /// retrying does not keep a session its owner has released alive; the
    /// loop then stops and the rest of the queue is dropped.
    private func startDraining() {
        let daemon = self.daemon
        let sleep = self.sleep
        let deviceName = self.deviceName
        let workQueue = self.workQueue
        let weakSelf: () -> CanvasSession? = { [weak self] in self }

        Task {
            while let job = weakSelf()?.dequeue() {
                switch job {
                case .capture(let capture):
                    await CanvasSession.runCapture(capture, daemon: daemon, workQueue: workQueue)
                case .annotation(let annotationJob):
                    await CanvasSession.runAnnotation(
                        annotationJob,
                        deviceName: deviceName,
                        daemon: daemon,
                        workQueue: workQueue,
                        sleep: sleep,
                        isAlive: { weakSelf() != nil }
                    )
                    weakSelf()?.finishAnnotationJob()
                }
            }
        }
    }

    /// One attempt, no retry: the annotation path re-posts the capture itself
    /// when this left no id behind.
    private static func runCapture(_ capture: FreezeCapture, daemon: DaemonAPI, workQueue: DispatchQueue) async {
        guard let png = await onWorkQueue(workQueue, { Compositor.pngData(capture.image) }) else {
            Log.info("canvas: freeze capture could not be encoded as PNG")
            return
        }
        do {
            capture.captureID = try await daemon.postCapture(png: png, width: capture.width, height: capture.height)
        } catch {
            Log.info("canvas: freeze capture post failed (\(error)); the annotation will re-post it")
        }
    }

    /// Composites once, then uploads until it succeeds. A sketch that will
    /// not decode is the one unrecoverable case — retrying cannot change it —
    /// so that annotation is dropped and the queue moves on. Everything else
    /// is retried behind `BackoffPolicy`, which later jobs wait out: losing a
    /// round's order would show the designer a reply for a sketch they drew
    /// after the one still in flight.
    ///
    /// A fresh policy per job is exactly "reset after a success", since the
    /// only way out of the loop is a successful upload or a dead session.
    private static func runAnnotation(
        _ job: AnnotationJob,
        deviceName: String,
        daemon: DaemonAPI,
        workQueue: DispatchQueue,
        sleep: (TimeInterval) async -> Void,
        isAlive: () -> Bool
    ) async {
        let composited = await onWorkQueue(workQueue, catching: {
            try Compositor.composite(base: job.capture.image, sketchPNG: job.sketchPNG, zoomRect: job.zoomRect)
        })
        guard case .success(let composite) = composited else {
            Log.info("canvas: dropping annotation — the sketch could not be composited")
            return
        }

        var backoff = BackoffPolicy()
        var repostedAfterMissingCapture = false

        while isAlive() {
            // The capture the freeze posted, or — when that post failed, or
            // the daemon has since lost it — one posted here from the
            // composite's own copy of the untouched frame.
            let captureID: String
            if let posted = job.capture.captureID {
                captureID = posted
            } else {
                do {
                    captureID = try await daemon.postCapture(
                        png: composite.screenshotPNG,
                        width: job.capture.width,
                        height: job.capture.height
                    )
                    job.capture.captureID = captureID
                } catch {
                    Log.info("canvas: capture post failed (\(error)); retrying the annotation")
                    await sleep(backoff.next())
                    continue
                }
            }

            let upload = AnnotationUpload(
                sourceCaptureId: captureID,
                compositePNG: composite.compositePNG,
                sketchPNG: composite.sketchPNG,
                viewport: job.viewport,
                zoomRect: job.zoomRect,
                note: job.note,
                deviceID: job.deviceID,
                deviceName: deviceName,
                createdAt: job.createdAt
            )
            do {
                let annotationID = try await daemon.postAnnotation(upload)
                Log.info("canvas: annotation \(annotationID) uploaded")
                return
            } catch DaemonClientError.captureNotFound where !repostedAfterMissingCapture {
                // The daemon's store lost (or never had) the capture: post it
                // again and try once more straight away, before falling back
                // to the ordinary backoff path.
                repostedAfterMissingCapture = true
                job.capture.captureID = nil
                Log.info("canvas: the daemon has no such capture; re-posting it")
            } catch {
                Log.info("canvas: annotation upload failed (\(error)); retrying")
                await sleep(backoff.next())
            }
        }
    }

    /// Hops to `workQueue` for CPU-bound image work and comes back with the
    /// result, so neither the sender's queue nor the pipeline's cooperative
    /// thread carries a PNG encode or a composite.
    private static func onWorkQueue<T>(_ queue: DispatchQueue, _ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    /// Same hop for work that throws; a `Result` rather than `rethrows`
    /// because the continuation has to carry the failure back out.
    private static func onWorkQueue<T>(_ queue: DispatchQueue, catching body: @escaping () throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result { try body() })
            }
        }
    }
}
