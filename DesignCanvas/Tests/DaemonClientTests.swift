import XCTest
import Foundation

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine straight into
// it (see project.yml), so DaemonClient and friends are available without an
// import.

final class DaemonClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: - helpers

    private func makeClient(sleep: @escaping (TimeInterval) async -> Void = { _ in }) -> DaemonClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return DaemonClient(
            baseURL: URL(string: "http://127.0.0.1:47100")!,
            configuration: configuration,
            sleep: sleep
        )
    }

    private func jsonObject(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - probe()

    func test_probe_healthyOn200_withAttachedChannel() async {
        let health = """
        {"status":"ok","version":"1.0.0","channelAttached":true,"pid":123,"instanceId":"abc",\
        "startedAt":"2026-01-01T00:00:00.000Z","serverEntry":"/x","port":47100,\
        "channelCount":2,"channelAttachedAt":"2026-01-01T00:00:01.000Z"}
        """
        StubURLProtocol.scripts = [.init(body: Data(health.utf8))]
        let client = makeClient()

        let result = await client.probe()

        guard case .healthy(let decoded) = result else { return XCTFail("expected .healthy, got \(result)") }
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.channelCount, 2)
        XCTAssertEqual(ChannelState(probe: result), .attached)
    }

    func test_probe_healthyOn200_withNoChannel_isDetached() async {
        let health = #"{"status":"ok","version":"1.0.0","channelAttached":false,"channelCount":0}"#
        StubURLProtocol.scripts = [.init(body: Data(health.utf8))]
        let client = makeClient()

        let result = await client.probe()

        XCTAssertEqual(ChannelState(probe: result), .detached)
    }

    func test_probe_foreignResponseOn200Garbage() async {
        StubURLProtocol.scripts = [.init(body: Data(#"{"hello":"world"}"#.utf8))]
        let client = makeClient()

        let result = await client.probe()

        XCTAssertEqual(result, .foreignResponse)
        XCTAssertEqual(ChannelState(probe: result), .none)
    }

    func test_probe_badStatusOn500() async {
        StubURLProtocol.scripts = [.init(statusCode: 500, body: Data("nope".utf8))]
        let client = makeClient()

        let result = await client.probe()

        XCTAssertEqual(result, .badStatus(500))
        XCTAssertEqual(ChannelState(probe: result), .none)
    }

    func test_probe_timedOut() async {
        StubURLProtocol.scripts = [.failing(URLError(.timedOut))]
        let client = makeClient()

        let result = await client.probe()

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(ChannelState(probe: result), .none)
    }

    func test_probe_refusedOnConnectionRefused() async {
        StubURLProtocol.scripts = [.failing(URLError(.cannotConnectToHost))]
        let client = makeClient()

        let result = await client.probe()

        XCTAssertEqual(result, .refused)
        XCTAssertEqual(ChannelState(probe: result), .none)
    }

    // MARK: - postCapture()

    func test_postCapture_sendsJSONBody_andParses201() async throws {
        StubURLProtocol.scripts = [.init(statusCode: 201, body: Data(#"{"captureId":"cap_1"}"#.utf8))]
        let client = makeClient()
        let png = Data([0x01, 0x02, 0x03])

        let captureId = try await client.postCapture(
            png: png,
            width: 100,
            height: 200,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_123.456)
        )

        XCTAssertEqual(captureId, "cap_1")
        guard let recorded = StubURLProtocol.recorded.last else { return XCTFail("expected a recorded request") }
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.url?.path, "/v1/captures")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "content-type"), "application/json")
        guard let body = jsonObject(recorded.body) else { return XCTFail("expected a JSON body") }
        XCTAssertEqual(body["screenshotBase64"] as? String, png.base64EncodedString())
        guard let viewport = body["viewport"] as? [String: Any] else { return XCTFail("expected viewport") }
        XCTAssertEqual(viewport["w"] as? Int, 100)
        XCTAssertEqual(viewport["h"] as? Int, 200)
        // M2: without this the daemon stamps its own receipt time, which is
        // minutes late for a capture that waited out a retry.
        XCTAssertEqual(body["createdAt"] as? String, "2023-11-14T22:15:23.456Z")
    }

    func test_postCapture_throwsBadStatusOn500() async {
        StubURLProtocol.scripts = [.init(statusCode: 500, body: Data("boom".utf8))]
        let client = makeClient()

        do {
            _ = try await client.postCapture(png: Data([0x01]), width: 1, height: 1, capturedAt: Date())
            XCTFail("expected a throw")
        } catch let error as DaemonClientError {
            XCTAssertEqual(error, .badStatus(500))
        } catch {
            XCTFail("expected DaemonClientError, got \(error)")
        }
    }

    // MARK: - postAnnotation()

    /// A minimal hand-rolled multipart reader, independent of the client's
    /// own encoder, so this test verifies wire shape rather than round-
    /// tripping through the same code it's testing.
    private func parseMultipart(_ body: Data, boundary: String) -> [String: (headers: String, data: Data)] {
        var parts: [String: (headers: String, data: Data)] = [:]
        let delimiter = Data("--\(boundary)".utf8)
        let headerTerminator = Data("\r\n\r\n".utf8)
        var cursor = body.startIndex

        while let boundaryRange = body.range(of: delimiter, in: cursor..<body.endIndex) {
            var partStart = boundaryRange.upperBound
            if body[partStart..<min(partStart + 2, body.endIndex)] == Data("--".utf8) {
                break
            }
            if body[partStart..<min(partStart + 2, body.endIndex)] == Data("\r\n".utf8) {
                partStart = body.index(partStart, offsetBy: 2)
            }
            guard let headerEndRange = body.range(of: headerTerminator, in: partStart..<body.endIndex) else { break }
            let headerText = String(decoding: body[partStart..<headerEndRange.lowerBound], as: UTF8.self)
            let dataStart = headerEndRange.upperBound
            let nextBoundaryMarker = Data("\r\n--\(boundary)".utf8)
            guard let nextBoundaryRange = body.range(of: nextBoundaryMarker, in: dataStart..<body.endIndex) else { break }
            let partData = body[dataStart..<nextBoundaryRange.lowerBound]
            if let nameRange = headerText.range(of: "name=\"") {
                let afterName = headerText[nameRange.upperBound...]
                if let endQuote = afterName.firstIndex(of: "\"") {
                    parts[String(afterName[afterName.startIndex..<endQuote])] = (headerText, Data(partData))
                }
            }
            cursor = body.index(nextBoundaryRange.lowerBound, offsetBy: 2)
        }
        return parts
    }

    private func boundary(from contentType: String?) -> String? {
        guard let contentType, let range = contentType.range(of: "boundary=") else { return nil }
        return String(contentType[range.upperBound...])
    }

    private func makeAnnotationUpload(zoomRect: NormalizedRect? = nil, note: String? = "  hello  ") -> AnnotationUpload {
        AnnotationUpload(
            sourceCaptureId: "cap_1",
            compositePNG: Data([0xAA, 0xBB, 0xCC]),
            sketchPNG: Data([0xDD, 0xEE]),
            viewport: CanvasViewport(width: 100, height: 200, scale: 2.0),
            zoomRect: zoomRect,
            note: note,
            deviceID: "dev-1",
            deviceName: "Irreel's iPad",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func test_postAnnotation_sendsMultipartWithThreeParts_andCorrectMetaFields() async throws {
        StubURLProtocol.scripts = [.init(statusCode: 201, body: Data(#"{"annotationId":"ann_1","dispatched":true}"#.utf8))]
        let client = makeClient()
        let upload = makeAnnotationUpload()

        let annotationId = try await client.postAnnotation(upload)

        XCTAssertEqual(annotationId, "ann_1")
        guard let recorded = StubURLProtocol.recorded.last, let body = recorded.body else {
            return XCTFail("expected a recorded request with a body")
        }
        let contentType = recorded.request.value(forHTTPHeaderField: "content-type")
        XCTAssertEqual(contentType?.hasPrefix("multipart/form-data; boundary="), true)
        guard let boundary = boundary(from: contentType) else { return XCTFail("expected a boundary") }

        let parts = parseMultipart(body, boundary: boundary)
        XCTAssertEqual(Set(parts.keys), ["meta", "composite", "sketch"])
        XCTAssertEqual(parts["composite"]?.data, upload.compositePNG)
        XCTAssertEqual(parts["sketch"]?.data, upload.sketchPNG)
        XCTAssertTrue(parts["composite"]?.headers.contains("filename=\"composite.png\"") ?? false)
        XCTAssertTrue(parts["composite"]?.headers.contains("Content-Type: image/png") ?? false)
        XCTAssertTrue(parts["sketch"]?.headers.contains("filename=\"sketch.png\"") ?? false)
        XCTAssertTrue(parts["meta"]?.headers.contains("Content-Type: application/json") ?? false)
        XCTAssertFalse(parts["meta"]?.headers.contains("filename=") ?? true)

        guard let metaData = parts["meta"]?.data, let meta = jsonObject(metaData) else {
            return XCTFail("expected meta JSON")
        }
        XCTAssertEqual(meta["sourceCaptureId"] as? String, "cap_1")
        guard let viewport = meta["viewport"] as? [String: Any] else { return XCTFail("expected viewport") }
        XCTAssertEqual(viewport["w"] as? Int, 100)
        XCTAssertEqual(viewport["h"] as? Int, 200)
        XCTAssertEqual(viewport["scale"] as? Double, 2.0)
        XCTAssertTrue(meta["zoomRect"] is NSNull)
        guard let device = meta["device"] as? [String: Any] else { return XCTFail("expected device") }
        XCTAssertEqual(device["id"] as? String, "dev-1")
        XCTAssertEqual(device["name"] as? String, "Irreel's iPad")
        guard let note = meta["note"] as? [String: Any] else { return XCTFail("expected note") }
        XCTAssertEqual(note["text"] as? String, "hello")
        guard let createdAt = meta["createdAt"] as? String else { return XCTFail("expected createdAt") }
        // ISO-8601 with fractional seconds in UTC, e.g. "2023-11-14T22:13:20.000Z".
        XCTAssertTrue(createdAt.hasSuffix("Z"))
        XCTAssertTrue(createdAt.contains("."))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: createdAt))
    }

    func test_postAnnotation_includesZoomRectObject_whenPresent() async throws {
        StubURLProtocol.scripts = [.init(statusCode: 201, body: Data(#"{"annotationId":"ann_1","dispatched":true}"#.utf8))]
        let client = makeClient()
        let upload = makeAnnotationUpload(zoomRect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))

        _ = try await client.postAnnotation(upload)

        guard let recorded = StubURLProtocol.recorded.last, let body = recorded.body,
              let boundary = boundary(from: recorded.request.value(forHTTPHeaderField: "content-type")) else {
            return XCTFail("expected a recorded multipart request")
        }
        let parts = parseMultipart(body, boundary: boundary)
        guard let metaData = parts["meta"]?.data, let meta = jsonObject(metaData),
              let zoomRect = meta["zoomRect"] as? [String: Any] else {
            return XCTFail("expected zoomRect object")
        }
        XCTAssertEqual(zoomRect["x"] as? Double, 0.1)
        XCTAssertEqual(zoomRect["y"] as? Double, 0.2)
        XCTAssertEqual(zoomRect["w"] as? Double, 0.3)
        XCTAssertEqual(zoomRect["h"] as? Double, 0.4)
    }

    func test_postAnnotation_omitsNoteKey_whenNoteIsNilOrBlank() async throws {
        for note in [nil, "   "] {
            StubURLProtocol.scripts = [.init(statusCode: 201, body: Data(#"{"annotationId":"ann_1","dispatched":true}"#.utf8))]
            let client = makeClient()
            let upload = makeAnnotationUpload(note: note)

            _ = try await client.postAnnotation(upload)

            guard let recorded = StubURLProtocol.recorded.last, let body = recorded.body,
                  let boundary = boundary(from: recorded.request.value(forHTTPHeaderField: "content-type")) else {
                return XCTFail("expected a recorded multipart request")
            }
            let parts = parseMultipart(body, boundary: boundary)
            guard let metaData = parts["meta"]?.data, let meta = jsonObject(metaData) else {
                return XCTFail("expected meta JSON")
            }
            XCTAssertNil(meta["note"], "note: \(String(describing: note))")
        }
    }

    func test_postAnnotation_maps404_toCaptureNotFound() async {
        StubURLProtocol.scripts = [.init(statusCode: 404, body: Data(#"{"error":"capture_not_found"}"#.utf8))]
        let client = makeClient()

        do {
            _ = try await client.postAnnotation(makeAnnotationUpload())
            XCTFail("expected a throw")
        } catch let error as DaemonClientError {
            XCTAssertEqual(error, .captureNotFound)
        } catch {
            XCTFail("expected DaemonClientError, got \(error)")
        }
    }

    // MARK: - rounds()

    func test_rounds_buildsQueryString_percentEncodesSpace_andDecodes() async throws {
        let roundsJSON = """
        {"rounds":[
            {"annotationId":"a1","createdAt":"2026-01-01T00:00:00.000Z","status":"queued"},
            {"annotationId":"a2","createdAt":"2026-01-01T00:00:01.000Z","status":"sent","message":"hi"}
        ]}
        """
        StubURLProtocol.scripts = [.init(body: Data(roundsJSON.utf8))]
        let client = makeClient()

        let rounds = try await client.rounds(deviceID: "dev with space", limit: 5)

        XCTAssertEqual(rounds.count, 2)
        XCTAssertEqual(rounds.first?.annotationId, "a1")
        XCTAssertEqual(rounds.first?.status, .queued)
        XCTAssertEqual(rounds.last?.message, "hi")

        guard let recorded = StubURLProtocol.recorded.last, let url = recorded.request.url else {
            return XCTFail("expected a recorded request")
        }
        XCTAssertEqual(url.path, "/v1/rounds")
        XCTAssertFalse(url.absoluteString.contains(" "))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "device" })?.value, "dev with space")
        XCTAssertEqual(queryItems.first(where: { $0.name == "limit" })?.value, "5")
    }

    // MARK: - roundUpdates()

    /// `URLRequest.timeoutInterval` is an *idle* timer, and its 60 s default
    /// cut an idle rounds stream off about once a minute — losing any
    /// `round.updated` emitted in the reconnect gap, which the daemon never
    /// replays (I2).
    func test_roundUpdates_requestsTheStreamWithAnHourLongIdleTimeout() async {
        let eventJSON = #"{"annotationId":"a1","createdAt":"2026-01-01T00:00:00.000Z","status":"queued","deviceId":"dev-1"}"#
        StubURLProtocol.scripts = [
            .init(statusCode: 200, bodyChunks: [Data("event: round.updated\ndata: \(eventJSON)\n\n".utf8)]),
        ]
        let client = makeClient()
        var iterator = client.roundUpdates().makeAsyncIterator()

        _ = await iterator.next()   // .connected
        _ = await iterator.next()   // the update

        guard let recorded = StubURLProtocol.recorded.first else {
            return XCTFail("expected a recorded request")
        }
        XCTAssertEqual(recorded.request.url?.path, "/v1/rounds/stream")
        XCTAssertEqual(recorded.request.timeoutInterval, 3_600)
    }

    /// The engine has no other way to know a gap happened, and a gap means a
    /// lost update: `.connected` is what makes it ask for a fresh snapshot.
    func test_roundUpdates_yieldsConnected_beforeEachConnectionsEvents() async {
        let firstEventJSON = #"{"annotationId":"a1","createdAt":"2026-01-01T00:00:00.000Z","status":"queued","deviceId":"dev-1"}"#
        let secondEventJSON = #"{"annotationId":"a2","createdAt":"2026-01-01T00:00:01.000Z","status":"sent","deviceId":"dev-1"}"#
        StubURLProtocol.scripts = [
            .init(statusCode: 200, bodyChunks: [Data("event: round.updated\ndata: \(firstEventJSON)\n\n".utf8)]),
            .init(statusCode: 200, bodyChunks: [Data("event: round.updated\ndata: \(secondEventJSON)\n\n".utf8)]),
        ]
        let client = makeClient()
        var iterator = client.roundUpdates().makeAsyncIterator()

        let connected = await iterator.next()
        XCTAssertEqual(connected, .connected)
        let first = await iterator.next()
        XCTAssertEqual(first, .update(RoundUpdate(
            deviceID: "dev-1",
            round: CanvasRound(annotationId: "a1", createdAt: "2026-01-01T00:00:00.000Z",
                               status: .queued, message: nil, prUrl: nil, note: nil)
        )))

        let reconnected = await iterator.next()
        XCTAssertEqual(reconnected, .connected, "the reconnect announces itself too")
        let second = await iterator.next()
        XCTAssertEqual(second, .update(RoundUpdate(
            deviceID: "dev-1",
            round: CanvasRound(annotationId: "a2", createdAt: "2026-01-01T00:00:01.000Z",
                               status: .sent, message: nil, prUrl: nil, note: nil)
        )))
    }

    func test_roundUpdates_deliversEvents_andReconnectsWithBackoffBetweenConnections() async {
        let firstEventJSON = #"{"annotationId":"a1","createdAt":"2026-01-01T00:00:00.000Z","status":"queued","deviceId":"dev-1"}"#
        let secondEventJSON = #"{"annotationId":"a2","createdAt":"2026-01-01T00:00:01.000Z","status":"sent","deviceId":"dev-1"}"#
        StubURLProtocol.scripts = [
            .init(
                statusCode: 200,
                bodyChunks: [Data("event: round.".utf8), Data("updated\ndata: \(firstEventJSON)\n\n".utf8)]
            ),
            .init(
                statusCode: 200,
                bodyChunks: [Data("event: round.updated\ndata: \(secondEventJSON)\n\n".utf8)]
            ),
        ]

        final class SleepRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [TimeInterval] = []
            func record(_ value: TimeInterval) {
                lock.lock(); defer { lock.unlock() }
                values.append(value)
            }
            var first: TimeInterval? {
                lock.lock(); defer { lock.unlock() }
                return values.first
            }
        }
        let recorder = SleepRecorder()
        let client = makeClient(sleep: { interval in recorder.record(interval) })

        let stream = client.roundUpdates()
        var iterator = stream.makeAsyncIterator()

        let connected = await iterator.next()
        XCTAssertEqual(connected, .connected)
        guard case .update(let first)? = await iterator.next() else {
            return XCTFail("expected the first round update")
        }
        XCTAssertEqual(first.deviceID, "dev-1")
        XCTAssertEqual(first.round.annotationId, "a1")
        XCTAssertEqual(first.round.status, .queued)

        let reconnected = await iterator.next()
        XCTAssertEqual(reconnected, .connected)
        guard case .update(let second)? = await iterator.next() else {
            return XCTFail("expected the second round update")
        }
        XCTAssertEqual(second.round.annotationId, "a2")
        XCTAssertEqual(second.round.status, .sent)

        XCTAssertEqual(recorder.first, 0.5)
    }
}
