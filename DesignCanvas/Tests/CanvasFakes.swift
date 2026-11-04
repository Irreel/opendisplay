import CoreVideo
import Foundation
import XCTest

// NOTE: this hostless bundle compiles Shared, Mac/Engine, Mac/Stream and the
// iPad's logic and receiver straight into it (see project.yml), so
// CanvasSession, DaemonAPI and CanvasOutbound are available without an import.

/// Records what a `CanvasSession` handed to its link, and answers with the
/// same synchronous rule `MirrorLink` uses: true means "could be framed",
/// never "delivered" (see `CanvasOutbound`).
final class FakeOutbound: CanvasOutbound {
    struct Sent {
        let type: String
        let object: [String: Any]
        let attachment: Data
    }

    private let lock = NSLock()
    private var storedSent: [Sent] = []

    /// Everything sent, in order.
    var sent: [Sent] { lock.withLock { storedSent } }

    /// Every message as its JSON object, with `type` in it as on the wire.
    var objects: [[String: Any]] {
        sent.map { message in
            var object = message.object
            object["type"] = message.type
            return object
        }
    }

    /// The objects whose `type` is `type`, in order.
    func objects(ofType type: String) -> [[String: Any]] {
        objects.filter { $0["type"] as? String == type }
    }

    @discardableResult
    func send(_ type: String, _ object: [String: Any], attachment: Data) -> Bool {
        guard WireCodec.message(type, object, attachment: attachment) != nil else { return false }
        lock.withLock { storedSent.append(Sent(type: type, object: object, attachment: attachment)) }
        return true
    }
}

/// A frame ring a test fills by hand.
final class FakeFrames: CleanFrameSource {
    private let lock = NSLock()
    private var frames: [UInt64: CleanFrame] = [:]

    func put(_ pixelBuffer: CVPixelBuffer, frame: UInt64, capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        lock.withLock { frames[frame] = CleanFrame(pixelBuffer: pixelBuffer, capturedAt: capturedAt) }
    }

    func cleanFrame(_ frame: UInt64) -> CleanFrame? {
        lock.withLock { frames[frame] }
    }
}

/// A scripted `DaemonAPI`. Every call is recorded; `captureResults` and
/// `annotationResults` are consumed front to back and, once exhausted, the
/// call succeeds with a fresh generated id (so "fail twice then succeed" is
/// two scripted failures and nothing else).
final class FakeDaemon: DaemonAPI {
    private let lock = NSLock()

    private var storedCaptureResults: [Result<String, Error>] = []
    private var storedAnnotationResults: [Result<String, Error>] = []
    private var storedRoundsResult: Result<[CanvasRound], Error> = .success([])

    private var storedCaptureCalls: [(png: Data, width: Int, height: Int, capturedAt: Date)] = []
    private var storedAnnotationCalls: [AnnotationUpload] = []
    private var storedRoundsCalls: [(deviceID: String, limit: Int)] = []
    private var updatesContinuation: AsyncStream<RoundStreamEvent>.Continuation?
    private var annotationsAlwaysFail = false

    /// Fired after the round-updates stream terminates.
    var onUpdatesTerminated: (() -> Void)?

    // MARK: - scripting

    func scriptCaptures(_ results: [Result<String, Error>]) {
        lock.withLock { storedCaptureResults = results }
    }

    func scriptAnnotations(_ results: [Result<String, Error>]) {
        lock.withLock { storedAnnotationResults = results }
    }

    func scriptRounds(_ result: Result<[CanvasRound], Error>) {
        lock.withLock { storedRoundsResult = result }
    }

    /// While set, every `postAnnotation` fails however often it is called —
    /// which is what holds a job in its retry loop for as long as a test needs
    /// it there. Clearing it lets the scripted/default results take over again.
    func setAnnotationsAlwaysFail(_ failing: Bool) {
        lock.withLock { annotationsAlwaysFail = failing }
    }

    // MARK: - recorded calls

    var captureCalls: [(png: Data, width: Int, height: Int, capturedAt: Date)] {
        lock.withLock { storedCaptureCalls }
    }

    var annotationCalls: [AnnotationUpload] { lock.withLock { storedAnnotationCalls } }

    var roundsCalls: [(deviceID: String, limit: Int)] { lock.withLock { storedRoundsCalls } }

    // MARK: - DaemonAPI

    func probe() async -> HealthProbeResult { .refused }

    func postCapture(png: Data, width: Int, height: Int, capturedAt: Date) async throws -> String {
        let result: Result<String, Error> = lock.withLock {
            storedCaptureCalls.append((png, width, height, capturedAt))
            let scripted = storedCaptureResults.isEmpty ? nil : storedCaptureResults.removeFirst()
            return scripted ?? .success("capture-\(storedCaptureCalls.count)")
        }
        return try result.get()
    }

    func postAnnotation(_ upload: AnnotationUpload) async throws -> String {
        let result: Result<String, Error> = lock.withLock {
            storedAnnotationCalls.append(upload)
            if annotationsAlwaysFail { return .failure(FakeDaemonFailure()) }
            let scripted = storedAnnotationResults.isEmpty ? nil : storedAnnotationResults.removeFirst()
            return scripted ?? .success("annotation-\(storedAnnotationCalls.count)")
        }
        return try result.get()
    }

    func rounds(deviceID: String, limit: Int) async throws -> [CanvasRound] {
        let result: Result<[CanvasRound], Error> = lock.withLock {
            storedRoundsCalls.append((deviceID, limit))
            return storedRoundsResult
        }
        return try result.get()
    }

    /// Yields `.connected` at once, as `DaemonClient` does when a connection
    /// is established, then whatever `emit`/`emitConnected` push into it.
    // MARK: - sessions (the Claude Code mod)

    private var storedTargetCalls: [(instance: String, fromIPad: Bool)] = []
    private var sessionsContinuation: AsyncStream<DaemonSessions>.Continuation?

    /// Every `setTarget` call, in order.
    var targetCalls: [(instance: String, fromIPad: Bool)] { lock.withLock { storedTargetCalls } }

    func setTarget(instance: String, fromIPad: Bool) async throws {
        lock.withLock { storedTargetCalls.append((instance, fromIPad)) }
    }

    func sessionUpdates() -> AsyncStream<DaemonSessions> {
        AsyncStream { continuation in
            lock.withLock { sessionsContinuation = continuation }
        }
    }

    /// What the daemon's sessions stream would send.
    func emitSessions(_ sessions: DaemonSessions) {
        lock.withLock { sessionsContinuation }?.yield(sessions)
    }

    func roundUpdates() -> AsyncStream<RoundStreamEvent> {
        AsyncStream { continuation in
            lock.withLock { updatesContinuation = continuation }
            continuation.onTermination = { [weak self] _ in self?.onUpdatesTerminated?() }
            continuation.yield(.connected)
        }
    }

    /// Pushes one update into the stream `roundUpdates()` handed out. Safe to
    /// call before anyone subscribes (it is then a no-op).
    func emit(_ update: RoundUpdate) {
        lock.withLock { updatesContinuation }?.yield(.update(update))
    }

    /// A reconnect: the stream was down, and is up again.
    func emitConnected() {
        lock.withLock { updatesContinuation }?.yield(.connected)
    }
}

/// A failure a fake daemon can be scripted with when the specific error does
/// not matter.
struct FakeDaemonFailure: Error, Equatable {}

extension XCTestCase {
    /// Spins the run loop until `condition` holds, or `timeout` elapses.
    /// Returns as soon as the condition is true, so a passing test never
    /// waits the full timeout (and never sleeps a fixed amount).
    @discardableResult
    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("timed out waiting for \(description)", file: file, line: line)
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        return true
    }
}
