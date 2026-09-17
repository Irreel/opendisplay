import Foundation
import XCTest

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine and
// Mac/SenderCanvasHooks.swift straight into it (see project.yml), so
// CanvasSession, DaemonAPI and CanvasOutbound are available without an import.

/// Records what a `CanvasSession` handed to the sender, and answers with the
/// same synchronous rule `MacSender` uses: true means "serialisable and under
/// the 32768-byte limit", never "delivered" (see `CanvasOutbound`).
final class FakeOutbound: CanvasOutbound {
    private let lock = NSLock()
    private var storedObjects: [[String: Any]] = []
    private var storedPayloads: [Data] = []

    /// Objects passed to `sendCanvasJSON`, in order.
    var objects: [[String: Any]] { lock.withLock { storedObjects } }

    /// Byte payloads passed to `sendCanvasJSONData`, in order.
    var payloads: [Data] { lock.withLock { storedPayloads } }

    /// The objects whose `type` is `type`, in order.
    func objects(ofType type: String) -> [[String: Any]] {
        objects.filter { $0["type"] as? String == type }
    }

    /// The payloads that parse as JSON objects with `type` == `type`, in order.
    func payloads(ofType type: String) -> [[String: Any]] {
        payloads.compactMap { data in
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["type"] as? String == type else { return nil }
            return object
        }
    }

    @discardableResult
    func sendCanvasJSON(_ object: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              let payload = try? JSONSerialization.data(withJSONObject: object),
              payload.count > 0, payload.count < CanvasWire.senderJSONLimit else { return false }
        lock.withLock { storedObjects.append(object) }
        return true
    }

    @discardableResult
    func sendCanvasJSONData(_ data: Data) -> Bool {
        guard data.count > 0, data.count < CanvasWire.senderJSONLimit else { return false }
        lock.withLock { storedPayloads.append(data) }
        return true
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

    private var storedCaptureCalls: [(png: Data, width: Int, height: Int)] = []
    private var storedAnnotationCalls: [AnnotationUpload] = []
    private var storedRoundsCalls: [(deviceID: String, limit: Int)] = []
    private var updatesContinuation: AsyncStream<RoundUpdate>.Continuation?

    /// Fired after each `postAnnotation` returns (success or failure), with
    /// the number of annotation calls made so far.
    var onAnnotationCall: ((Int) -> Void)?
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

    // MARK: - recorded calls

    var captureCalls: [(png: Data, width: Int, height: Int)] { lock.withLock { storedCaptureCalls } }

    var annotationCalls: [AnnotationUpload] { lock.withLock { storedAnnotationCalls } }

    var roundsCalls: [(deviceID: String, limit: Int)] { lock.withLock { storedRoundsCalls } }

    // MARK: - DaemonAPI

    func probe() async -> HealthProbeResult { .refused }

    func postCapture(png: Data, width: Int, height: Int) async throws -> String {
        let result: Result<String, Error> = lock.withLock {
            storedCaptureCalls.append((png, width, height))
            let scripted = storedCaptureResults.isEmpty ? nil : storedCaptureResults.removeFirst()
            return scripted ?? .success("capture-\(storedCaptureCalls.count)")
        }
        return try result.get()
    }

    func postAnnotation(_ upload: AnnotationUpload) async throws -> String {
        let (result, count): (Result<String, Error>, Int) = lock.withLock {
            storedAnnotationCalls.append(upload)
            let scripted = storedAnnotationResults.isEmpty ? nil : storedAnnotationResults.removeFirst()
            let count = storedAnnotationCalls.count
            return (scripted ?? .success("annotation-\(count)"), count)
        }
        defer { onAnnotationCall?(count) }
        return try result.get()
    }

    func rounds(deviceID: String, limit: Int) async throws -> [CanvasRound] {
        let result: Result<[CanvasRound], Error> = lock.withLock {
            storedRoundsCalls.append((deviceID, limit))
            return storedRoundsResult
        }
        return try result.get()
    }

    func roundUpdates() -> AsyncStream<RoundUpdate> {
        AsyncStream { continuation in
            lock.withLock { updatesContinuation = continuation }
            continuation.onTermination = { [weak self] _ in self?.onUpdatesTerminated?() }
        }
    }

    /// Pushes one update into the stream `roundUpdates()` handed out. Safe to
    /// call before anyone subscribes (it is then a no-op).
    func emit(_ update: RoundUpdate) {
        lock.withLock { updatesContinuation }?.yield(update)
    }

    /// True once `roundUpdates()` has been called and its continuation stored.
    var hasSubscriber: Bool { lock.withLock { updatesContinuation != nil } }
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
