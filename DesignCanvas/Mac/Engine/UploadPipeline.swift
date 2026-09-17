import CoreGraphics
import Dispatch
import Foundation

/// The serial queue of daemon uploads one canvas session has accepted.
///
/// It is its own object, rather than a couple of fields on `CanvasSession`,
/// because an accepted sketch has to outlive the connection it arrived on.
/// The iPad leaves DRAWING the moment it has written the `annotation` frame —
/// that is what "sent" means on the device (ruling 5) — so from then on the
/// round is the Mac's to deliver, and the daemon may be down for minutes
/// (PRD D5, technical_doc section 11: "Annotation held in the engine, retried
/// with backoff"). A sender session, meanwhile, dies the moment the device
/// disconnects.
///
/// So the drain task holds the pipeline strongly for exactly as long as jobs
/// remain, and the pipeline goes away with its last job. What it does *not*
/// hold is the session, its frame ring (full-size deep copies of up to 16
/// frames) or the link: a job carries only its own frozen frame and sketch.
final class UploadPipeline {

    /// A frozen frame waiting for its sketch.
    final class FreezeCapture {
        let image: CGImage
        let width: Int
        let height: Int

        private let lock = NSLock()
        private var storedCaptureID: String?

        /// Set by the capture job, read (and cleared, on `.captureNotFound`)
        /// by the annotation job. Usually both run on the same serial
        /// pipeline, which hands the capture job out first — but a capture
        /// parked across a link drop (`CanvasCaptureParkingLot`) is posted by
        /// one session's pipeline and consumed by the next session's, so the
        /// two accesses are not always on the same queue. Once per freeze and
        /// once per annotation, so the lock costs nothing that matters.
        var captureID: String? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedCaptureID
            }
            set {
                lock.lock()
                storedCaptureID = newValue
                lock.unlock()
            }
        }

        init(image: CGImage) {
            self.image = image
            self.width = image.width
            self.height = image.height
        }
    }

    /// Everything an `annotation` needs once the sender's queue is released.
    struct AnnotationJob {
        let capture: FreezeCapture
        let sketchPNG: Data
        let zoomRect: NormalizedRect
        let viewport: CanvasViewport
        let note: String?
        let deviceID: String
        let createdAt: Date
    }

    private enum Job {
        case capture(FreezeCapture)
        case annotation(AnnotationJob)
    }

    private let deviceName: String
    private let daemon: DaemonAPI
    private let workQueue: DispatchQueue
    private let sleep: (TimeInterval) async -> Void

    private let lock = NSLock()
    private var jobs: [Job] = []
    private var draining = false
    private var pendingUploads = 0

    init(
        deviceName: String,
        daemon: DaemonAPI,
        workQueue: DispatchQueue,
        sleep: @escaping (TimeInterval) async -> Void
    ) {
        self.deviceName = deviceName
        self.daemon = daemon
        self.workQueue = workQueue
        self.sleep = sleep
    }

    /// Annotations accepted but not yet uploaded or dropped.
    var pendingUploadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingUploads
    }

    func enqueue(capture: FreezeCapture) {
        enqueue(.capture(capture))
    }

    func enqueue(annotation job: AnnotationJob) {
        enqueue(.annotation(job))
    }

    // MARK: - the queue

    private func enqueue(_ job: Job) {
        lock.lock()
        jobs.append(job)
        if case .annotation = job {
            pendingUploads += 1
        }
        let needsDrainer = !draining
        if needsDrainer {
            draining = true
        }
        lock.unlock()

        guard needsDrainer else { return }
        startDraining()
    }

    private func dequeue() -> Job? {
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

    /// One task, one job at a time, strictly in order. It captures `self`
    /// strongly on purpose: that is what makes the queue survive its session.
    /// The task ends as soon as the queue runs dry, and with it the last
    /// reference to the pipeline.
    private func startDraining() {
        Task {
            var backoff = BackoffPolicy()
            while let job = self.dequeue() {
                switch job {
                case .capture(let capture):
                    await self.runCapture(capture)
                case .annotation(let annotationJob):
                    await self.runAnnotation(annotationJob, backoff: &backoff)
                    self.finishAnnotationJob()
                }
            }
        }
    }

    // MARK: - the jobs

    /// One attempt, no retry: the annotation path re-posts the capture itself
    /// when this left no id behind.
    private func runCapture(_ capture: FreezeCapture) async {
        guard let png = await onWorkQueue({ Compositor.pngData(capture.image) }) else {
            Log.info("canvas: freeze capture could not be encoded as PNG")
            return
        }
        do {
            capture.captureID = try await daemon.postCapture(png: png, width: capture.width, height: capture.height)
        } catch {
            Log.info("canvas: freeze capture post failed (\(error)); the annotation will re-post it")
        }
    }

    /// Composites once, then uploads until it succeeds. A sketch that will not
    /// decode is the one unrecoverable case — retrying cannot change it — so
    /// that annotation is dropped and the queue moves on. Everything else is
    /// retried behind `backoff`, which later jobs wait out: losing a round's
    /// order would show the designer a reply for a sketch they drew after the
    /// one still in flight.
    ///
    /// `backoff` is the drainer's, not this job's, so a daemon that has been
    /// down for a while is not hammered afresh by every queued round; it is
    /// reset the moment an upload lands.
    private func runAnnotation(_ job: AnnotationJob, backoff: inout BackoffPolicy) async {
        let composited = await onWorkQueue(catching: {
            try Compositor.composite(base: job.capture.image, sketchPNG: job.sketchPNG, zoomRect: job.zoomRect)
        })
        guard case .success(let composite) = composited else {
            Log.info("canvas: dropping annotation — the sketch could not be composited")
            return
        }

        var repostedAfterMissingCapture = false

        while true {
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
                backoff.reset()
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

    // MARK: - hopping to the work queue

    /// Runs CPU-bound image work on `workQueue` and comes back with the
    /// result, so neither the sender's queue nor the drainer's cooperative
    /// thread carries a PNG encode or a composite.
    private func onWorkQueue<T>(_ body: @escaping () -> T) async -> T {
        let queue = workQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    /// Same hop for work that throws; a `Result` rather than `rethrows`
    /// because the continuation has to carry the failure back out.
    private func onWorkQueue<T>(catching body: @escaping () throws -> T) async -> Result<T, Error> {
        let queue = workQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result { try body() })
            }
        }
    }
}
