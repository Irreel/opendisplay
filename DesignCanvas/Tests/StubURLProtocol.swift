import Foundation

/// Intercepts every request made through a `URLSession` configured with
/// `protocolClasses = [StubURLProtocol.self]` and answers with the next
/// queued `Script`, consumed FIFO — one script per intercepted request (one
/// HTTP call, or one `roundUpdates()` connection attempt).
///
/// Tests reset `scripts`/`recorded` in `setUp()`. Each test builds its own
/// `URLSessionConfiguration`/`DaemonClient`, so this shared static state only
/// needs to not leak *values* across tests, not be per-instance.
final class StubURLProtocol: URLProtocol {

    struct Recorded {
        let request: URLRequest
        /// The outgoing body, however URLSession chose to deliver it to the
        /// protocol (`httpBody` directly, or `httpBodyStream` — Foundation
        /// often moves a request's body into a stream by the time a custom
        /// protocol sees it, so both are handled).
        let body: Data?
    }

    struct Script {
        var statusCode: Int
        var headers: [String: String]
        /// Delivered as one `urlProtocol(_:didLoad:)` call per chunk, so a
        /// streaming response can prove data split across delivery chunks
        /// still parses correctly on the receiving end.
        var bodyChunks: [Data]
        var error: URLError?

        init(statusCode: Int = 200, headers: [String: String] = [:], body: Data = Data(), error: URLError? = nil) {
            self.statusCode = statusCode
            self.headers = headers
            self.bodyChunks = body.isEmpty ? [] : [body]
            self.error = error
        }

        init(statusCode: Int, headers: [String: String] = [:], bodyChunks: [Data]) {
            self.statusCode = statusCode
            self.headers = headers
            self.bodyChunks = bodyChunks
            self.error = nil
        }

        static func failing(_ error: URLError) -> Script {
            Script(statusCode: -1, error: error)
        }
    }

    static var scripts: [Script] = []
    static var recorded: [Recorded] = []

    static func reset() {
        scripts = []
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.recorded.append(Recorded(request: request, body: StubURLProtocol.readBody(from: request)))

        guard !StubURLProtocol.scripts.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let script = StubURLProtocol.scripts.removeFirst()

        if let error = script.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: script.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: script.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in script.bodyChunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `httpBody` is frequently nil by the time a registered `URLProtocol`
    /// sees the request — the URL loading system moves it into
    /// `httpBodyStream` instead. Read whichever is present.
    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 32 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
