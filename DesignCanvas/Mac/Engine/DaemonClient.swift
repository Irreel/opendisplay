import Foundation

/// `GET /v1/health` response shape. Identity fields (`pid`, `instanceId`, …)
/// are absent from a legacy daemon, hence optional.
struct DaemonHealth: Decodable, Equatable {
    let status: String
    let version: String
    let channelAttached: Bool
    let pid: Int?
    let instanceId: String?
    let startedAt: String?
    let serverEntry: String?
    let port: Int?
    let channelCount: Int?
    let channelAttachedAt: String?
}

/// Every outcome `probe()` can report. Never throws: a caller (health
/// polling) needs to distinguish "nothing is listening" from "something
/// foreign is listening" from "our daemon, but unhealthy" without a catch
/// block per case.
enum HealthProbeResult: Equatable {
    case healthy(DaemonHealth)
    case refused
    case timedOut
    case badStatus(Int)
    case foreignResponse
}

/// Everything needed to build one `POST /v1/annotations` upload. Field names
/// mirror the daemon's meta JSON keys (see `task-6-report.md`), not the wire
/// `AnnotationMessage` from the iPad, since a zoom rect / viewport / note
/// value must survive whatever the engine did with the incoming annotation
/// before it reaches the daemon.
struct AnnotationUpload: Equatable {
    var sourceCaptureId: String
    var compositePNG: Data
    var sketchPNG: Data
    var viewport: CanvasViewport
    var zoomRect: NormalizedRect?
    var note: String?
    var deviceID: String
    var deviceName: String
    var createdAt: Date
}

/// One `round.updated` SSE event, tagged with the device it belongs to (the
/// daemon's `RoundEvent` is a `Round` plus `deviceId`).
struct RoundUpdate: Equatable {
    let deviceID: String
    let round: CanvasRound
}

/// One item from the daemon's rounds stream.
///
/// `.connected` is how the engine learns a connection was just established,
/// and it always precedes that connection's updates. It matters because the
/// daemon has no event replay: a `round.updated` emitted while the stream was
/// down is simply gone, and the only cure is to ask for a fresh snapshot
/// (`CanvasHub`, I2).
enum RoundStreamEvent: Equatable {
    case connected
    case update(RoundUpdate)
}

enum DaemonClientError: Error, Equatable {
    case badStatus(Int)
    case undecodable
    case captureNotFound
}

/// One dispatched Server-Sent Event, decoded from a byte stream by `SSEParser`.
protocol DaemonAPI: AnyObject {
    func probe() async -> HealthProbeResult
    /// `capturedAt` is the frame's own time (the ring entry's `captureMs`), not now:
    /// the daemon otherwise stamps its receipt time, which is minutes late for a
    /// capture that waited out a retry, and that stamp is the "Captured at" the
    /// channel reports to the model (M2).
    func postCapture(png: Data, width: Int, height: Int, capturedAt: Date) async throws -> String
    func postAnnotation(_ upload: AnnotationUpload) async throws -> String
    func rounds(deviceID: String, limit: Int) async throws -> [CanvasRound]
    /// Reconnects forever with backoff until the stream is cancelled (see
    /// `DaemonClient.roundUpdates()`).
    func roundUpdates() -> AsyncStream<RoundStreamEvent>
}

/// The Mac engine's one client for the local Node daemon at
/// `http://127.0.0.1:47100`: health, capture/annotation uploads, the rounds
/// list, and the rounds SSE stream. Every request/response shape here must
/// match the daemon exactly — see `task-6-report.md`'s route table and
/// `DesignCanvas/server/src/http/server.ts`/`shared.ts`.
final class DaemonClient: DaemonAPI {
    private let baseURL: URL
    private let session: URLSession
    private let sleep: (TimeInterval) async -> Void

    /// ISO-8601 with fractional seconds in UTC — the same format JavaScript's
    /// `toISOString()` produces, which is what the daemon's own `createdAt`
    /// values use, so an engine-supplied `createdAt` sorts consistently
    /// alongside daemon-generated ones.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:47100")!,
        configuration: URLSessionConfiguration = .ephemeral,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.baseURL = baseURL
        self.session = URLSession(configuration: configuration)
        self.sleep = sleep
    }

    // MARK: - probe()

    /// Never throws: every transport/decode outcome maps to a
    /// `HealthProbeResult` case (ai.cst.2's `HealthClient.probe()` mapping).
    func probe() async -> HealthProbeResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/health"))
        request.timeoutInterval = 1.5

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            return error.code == .timedOut ? .timedOut : .refused
        } catch {
            return .refused
        }
        guard let http = response as? HTTPURLResponse else { return .refused }
        guard http.statusCode == 200 else { return .badStatus(http.statusCode) }
        guard let health = try? JSONDecoder().decode(DaemonHealth.self, from: data) else { return .foreignResponse }
        return .healthy(health)
    }

    // MARK: - postCapture()

    func postCapture(png: Data, width: Int, height: Int, capturedAt: Date) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/captures"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "screenshotBase64": png.base64EncodedString(),
            "viewport": ["w": width, "h": height],
            "createdAt": DaemonClient.isoFormatter.string(from: capturedAt),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DaemonClientError.undecodable }
        guard http.statusCode == 201 else { throw DaemonClientError.badStatus(http.statusCode) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let captureId = object["captureId"] as? String else { throw DaemonClientError.undecodable }
        return captureId
    }

    // MARK: - postAnnotation()

    func postAnnotation(_ upload: AnnotationUpload) async throws -> String {
        let boundary = "DesignCanvas-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/annotations"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.httpBody = DaemonClient.multipartBody(for: upload, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DaemonClientError.undecodable }
        guard http.statusCode == 201 else {
            if http.statusCode == 404 { throw DaemonClientError.captureNotFound }
            throw DaemonClientError.badStatus(http.statusCode)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let annotationId = object["annotationId"] as? String else { throw DaemonClientError.undecodable }
        return annotationId
    }

    private static func multipartBody(for upload: AnnotationUpload, boundary: String) -> Data {
        var meta: [String: Any] = [
            "sourceCaptureId": upload.sourceCaptureId,
            "viewport": upload.viewport.json,
            "zoomRect": upload.zoomRect?.json ?? NSNull(),
            "device": ["id": upload.deviceID, "name": upload.deviceName],
            "createdAt": isoFormatter.string(from: upload.createdAt),
        ]
        if let note = upload.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            meta["note"] = ["text": note]
        }
        // Meta/device/zoomRect are all JSON-serializable literals built above, so this cannot fail.
        let metaData = (try? JSONSerialization.data(withJSONObject: meta)) ?? Data()

        var body = Data()
        appendPart(name: "meta", contentType: "application/json", data: metaData, isFile: false, boundary: boundary, into: &body)
        appendPart(name: "composite", contentType: "image/png", data: upload.compositePNG, isFile: true, boundary: boundary, into: &body)
        appendPart(name: "sketch", contentType: "image/png", data: upload.sketchPNG, isFile: true, boundary: boundary, into: &body)
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// Appends one multipart part. File parts get `filename="<name>.png"`
    /// (the meta part has no filename), CRLF throughout, matching the
    /// daemon's hand-rolled parser (`server/src/http/multipart.ts`).
    private static func appendPart(name: String, contentType: String, data: Data, isFile: Bool, boundary: String, into body: inout Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        if isFile {
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).png\"\r\n".utf8))
        } else {
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n".utf8))
        }
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    // MARK: - rounds()

    func rounds(deviceID: String, limit: Int) async throws -> [CanvasRound] {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("v1/rounds"), resolvingAgainstBaseURL: false) else {
            throw DaemonClientError.undecodable
        }
        components.queryItems = [
            URLQueryItem(name: "device", value: deviceID),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { throw DaemonClientError.undecodable }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw DaemonClientError.undecodable }
        guard http.statusCode == 200 else { throw DaemonClientError.badStatus(http.statusCode) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let roundsJSON = object["rounds"] as? [[String: Any]] else { throw DaemonClientError.undecodable }

        // An entry this build cannot read is skipped, not fatal (M6): one
        // unreadable round must not cost the device the whole snapshot the next
        // hello sends. A missing `rounds` key above is still undecodable — that
        // is not a rounds response at all.
        let rounds = roundsJSON.compactMap(CanvasRound.init(json:))
        if rounds.count != roundsJSON.count {
            Log.info("DaemonClient: skipped \(roundsJSON.count - rounds.count) unreadable round(s)")
        }
        return rounds
    }

    // MARK: - roundUpdates()

    /// One long-lived connection at a time via `URLSession.bytes(for:)`
    /// (never `.lines`, which drops the blank lines that delimit SSE
    /// frames). A non-200 response, a transport error, or the stream simply
    /// ending all count as a failed connection and trigger `backoff.next()`
    /// before reconnecting; backoff resets — and `.connected` is yielded —
    /// once the first byte of a 200 connection arrives. Runs until the
    /// returned stream is cancelled — `onTermination` fires when the consumer
    /// stops iterating (including when the stream is deallocated), which
    /// cancels the underlying `Task`.
    ///
    /// `timeoutInterval` is an *idle* timer, and its 60 s default cut this
    /// stream off about once a minute: an hour is long enough that only a real
    /// outage ends a connection, while the daemon's 15 s keep-alive comment
    /// means an idle-but-live stream never trips it at all (I2).
    func roundUpdates() -> AsyncStream<RoundStreamEvent> {
        let baseURL = self.baseURL
        let session = self.session
        let sleep = self.sleep

        return AsyncStream { continuation in
            let task = Task {
                var backoff = BackoffPolicy()
                while !Task.isCancelled {
                    var parser = SSEParser()
                    var receivedFirstByte = false
                    do {
                        var request = URLRequest(url: baseURL.appendingPathComponent("v1/rounds/stream"))
                        request.timeoutInterval = 3_600
                        let (byteStream, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                            throw DaemonClientError.badStatus(status)
                        }
                        for try await byte in byteStream {
                            if Task.isCancelled { break }
                            if !receivedFirstByte {
                                receivedFirstByte = true
                                backoff.reset()
                                continuation.yield(.connected)
                            }
                            for event in parser.feed(Data([byte])) where event.event == "round.updated" {
                                if let update = DaemonClient.decodeRoundUpdate(event.data) {
                                    continuation.yield(.update(update))
                                }
                            }
                        }
                    } catch {
                        if Task.isCancelled { break }
                        Log.info("DaemonClient: rounds stream connection failed: \(error)")
                    }
                    if Task.isCancelled { break }
                    await sleep(backoff.next())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The daemon's `RoundEvent` is a `Round` plus `deviceId`; build a
    /// `CanvasRound` from the same dictionary and read `deviceId` separately.
    /// An event without a string `deviceId`, or with an otherwise invalid
    /// round, is skipped.
    private static func decodeRoundUpdate(_ jsonText: String) -> RoundUpdate? {
        guard let data = jsonText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let deviceID = object["deviceId"] as? String,
              let round = CanvasRound(json: object) else { return nil }
        return RoundUpdate(deviceID: deviceID, round: round)
    }
}
