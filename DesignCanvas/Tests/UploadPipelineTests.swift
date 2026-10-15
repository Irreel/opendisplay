import CoreGraphics
import Foundation
import XCTest

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine straight into
// it (see project.yml), so UploadPipeline is available without an import.
//
// `CanvasSessionTests` drives the pipeline through a session, which is how the
// freeze/annotation pairing is tested. These cases are about the queue itself:
// which failures are worth retrying, and what happens when it fills up.

final class UploadPipelineTests: XCTestCase {

    private func makePipeline(
        daemon: FakeDaemon,
        sleep: @escaping (TimeInterval) async -> Void = { _ in await Task.yield() }
    ) -> UploadPipeline {
        UploadPipeline(
            deviceName: "Zhao's iPad",
            daemon: daemon,
            workQueue: DispatchQueue(label: "test.upload.work", qos: .utility),
            sleep: sleep
        )
    }

    private func capture(posted id: String? = "capture-1") -> UploadPipeline.FreezeCapture {
        let capture = UploadPipeline.FreezeCapture(
            image: TestImages.solidCGImage(width: 8, height: 6, color: TestImages.RGBA(0, 0, 200)),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        capture.captureID = id
        return capture
    }

    /// An annotation job whose `note` names it, so a test can say which jobs
    /// reached the daemon and which were dropped.
    private func job(_ name: String, capture: UploadPipeline.FreezeCapture) -> UploadPipeline.AnnotationJob {
        UploadPipeline.AnnotationJob(
            base: .frame(capture),
            sketchPNG: Data(),
            zoomRect: .full,
            viewport: CanvasViewport(width: 8, height: 6, scale: 2),
            note: name,
            deviceID: "install-A",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func uploadedNotes(_ daemon: FakeDaemon) -> [String] {
        daemon.annotationCalls.compactMap(\.note)
    }

    // MARK: - which failures are worth retrying

    func test_a400_dropsTheJob_andTheQueueMovesOn() {
        let daemon = FakeDaemon()
        daemon.scriptAnnotations([.failure(DaemonClientError.badStatus(400))])
        let delays = DelayRecorder()
        let pipeline = makePipeline(daemon: daemon, sleep: { delays.record($0) })
        let shared = capture()

        pipeline.enqueue(annotation: job("first", capture: shared))
        pipeline.enqueue(annotation: job("second", capture: shared))

        guard waitUntil("the second job to be uploaded", { daemon.annotationCalls.count == 2 }) else { return }
        XCTAssertEqual(uploadedNotes(daemon), ["first", "second"], "the 400 was attempted once, not retried")
        XCTAssertEqual(delays.all, [], "a request the daemon refuses outright is not backed off")
        waitUntil("the pending count to fall back to zero") { pipeline.pendingUploadCount == 0 }
    }

    func test_a413_dropsTheJob() {
        let daemon = FakeDaemon()
        daemon.scriptAnnotations([.failure(DaemonClientError.badStatus(413))])
        let pipeline = makePipeline(daemon: daemon)
        let shared = capture()

        pipeline.enqueue(annotation: job("too big", capture: shared))
        pipeline.enqueue(annotation: job("next", capture: shared))

        guard waitUntil("the next job to be uploaded", { daemon.annotationCalls.count == 2 }) else { return }
        XCTAssertEqual(uploadedNotes(daemon), ["too big", "next"])
    }

    func test_a429_a408_and_a500_areRetried() {
        for status in [408, 429, 500] {
            let daemon = FakeDaemon()
            daemon.scriptAnnotations([.failure(DaemonClientError.badStatus(status))])
            let pipeline = makePipeline(daemon: daemon)

            pipeline.enqueue(annotation: job("retry me", capture: capture()))

            guard waitUntil("the \(status) to be retried to success", { daemon.annotationCalls.count == 2 })
            else { return }
            XCTAssertEqual(uploadedNotes(daemon), ["retry me", "retry me"], "status \(status)")
        }
    }

    /// The capture post has the same classification: a 400 there is not going
    /// to become a 201, and the round behind it must not wait for ever.
    func test_aNonRetryableCapturePost_dropsTheJob_andTheQueueMovesOn() {
        let daemon = FakeDaemon()
        daemon.scriptCaptures([.failure(DaemonClientError.badStatus(400))])
        let pipeline = makePipeline(daemon: daemon)

        pipeline.enqueue(annotation: job("unpostable", capture: capture(posted: nil)))
        pipeline.enqueue(annotation: job("next", capture: capture()))

        guard waitUntil("the next job to be uploaded", { daemon.annotationCalls.count == 1 }) else { return }
        XCTAssertEqual(uploadedNotes(daemon), ["next"])
        XCTAssertEqual(daemon.captureCalls.count, 1, "the refused capture post was attempted once")
    }

    func test_isNonRetryable_classifiesTheDaemonsStatuses() {
        XCTAssertTrue(UploadPipeline.isNonRetryable(DaemonClientError.badStatus(400)))
        XCTAssertTrue(UploadPipeline.isNonRetryable(DaemonClientError.badStatus(403)))
        XCTAssertTrue(UploadPipeline.isNonRetryable(DaemonClientError.badStatus(413)))
        XCTAssertFalse(UploadPipeline.isNonRetryable(DaemonClientError.badStatus(404)))
        XCTAssertFalse(UploadPipeline.isNonRetryable(DaemonClientError.badStatus(408)))
        XCTAssertFalse(UploadPipeline.isNonRetryable(DaemonClientError.badStatus(429)))
        XCTAssertFalse(UploadPipeline.isNonRetryable(DaemonClientError.badStatus(500)))
        XCTAssertFalse(UploadPipeline.isNonRetryable(DaemonClientError.badStatus(503)))
        XCTAssertFalse(UploadPipeline.isNonRetryable(DaemonClientError.undecodable))
        XCTAssertFalse(UploadPipeline.isNonRetryable(FakeDaemonFailure()))
    }

    // MARK: - the queue's bound

    /// A daemon that is down for hours would otherwise let the queue grow
    /// without limit, each job holding a full-resolution frame.
    func test_theQueueIsBoundedAt50Jobs_droppingTheOldestPendingOne() {
        let daemon = FakeDaemon()
        daemon.setAnnotationsAlwaysFail(true)
        let pipeline = makePipeline(daemon: daemon)
        let shared = capture()

        // The first job is dequeued at once and parks in its retry loop, so
        // everything below queues up behind it.
        pipeline.enqueue(annotation: job("0", capture: shared))
        guard waitUntil("the first job to be retrying", { daemon.annotationCalls.count >= 2 }) else {
            daemon.setAnnotationsAlwaysFail(false)
            return
        }
        for index in 1...60 {
            pipeline.enqueue(annotation: job("\(index)", capture: shared))
        }
        XCTAssertEqual(pipeline.pendingUploadCount, UploadPipeline.maxQueuedJobs + 1,
                       "50 queued plus the one in flight")

        daemon.setAnnotationsAlwaysFail(false)
        guard waitUntil("the queue to drain", { pipeline.pendingUploadCount == 0 }) else { return }

        let uploaded = Set(uploadedNotes(daemon))
        XCTAssertTrue(uploaded.contains("0"), "the job in flight is never the one dropped")
        for index in 1...10 {
            XCTAssertFalse(uploaded.contains("\(index)"), "\(index) is one of the oldest, dropped ones")
        }
        for index in 11...60 {
            XCTAssertTrue(uploaded.contains("\(index)"), "\(index) survived")
        }
    }
}

/// Records the backoff intervals a pipeline slept for, from whatever thread
/// its drainer is on.
final class DelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
