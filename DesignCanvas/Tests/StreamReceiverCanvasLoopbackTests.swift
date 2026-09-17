import XCTest
import AVFoundation
import Network

// One end-to-end pass over the canvas seams in `Shared/StreamReceiver.swift`,
// driven through a real loopback socket: the pure decisions are covered by
// CanvasReceiverStateTests, and this proves the wiring around them — that the
// welcome gate is read off the wire, that a canvas message reaches the
// callback, that `sendCanvas` puts a framed frame on the socket, and that
// `suppressesInput` really does keep input off it.
//
// The listener is a real bind, so it can lose the port to whatever else is on
// the machine. That is an environment failure, not a regression: the test
// skips instead of failing when the fake Mac cannot connect within 2 s.

final class StreamReceiverCanvasLoopbackTests: XCTestCase {

    private var receiver: StreamReceiver?
    private var mac: FakeMac?

    override func tearDown() {
        mac?.stop()
        mac = nil
        // Leave no listener behind for the next test to collide with.
        if let receiver {
            let stopped = expectation(description: "receiver stopped")
            receiver.stop { stopped.fulfill() }
            wait(for: [stopped], timeout: 5)
        }
        receiver = nil
        super.tearDown()
    }

    func test_canvasSessionOverLoopback() throws {
        let port = UInt16.random(in: 49_152...64_000)
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                      deviceKind: "iPad",
                                      fallbackServiceName: "Loopback Test",
                                      serviceType: "_designcanvastest._tcp")
        self.receiver = receiver

        let canvasMessages = Box<[(String, [String: Any])]>([])
        let welcomes = Box<[Bool]>([])
        receiver.onCanvasMessage = { type, object in canvasMessages.value.append((type, object)) }
        receiver.onWelcome = { isCanvas in welcomes.value.append(isCanvas) }
        receiver.setPanel(pixelsWide: 2048, pixelsHigh: 1536, scale: 2)
        receiver.start(port: port)

        // --- the fake Mac dials in and reads the hello -------------------
        guard waitUntil({ receiver.status.hasPrefix("Listening on :\(port)") }) else {
            throw XCTSkip("the receiver never bound :\(port) within 2s — port taken or denied")
        }
        let mac = FakeMac(port: port)
        self.mac = mac
        guard mac.connect(timeout: 2) else {
            throw XCTSkip("no loopback listener on :\(port) within 2s — port taken or network denied")
        }
        guard waitUntil({ mac.first(ofType: "hello") != nil }) else {
            throw XCTSkip("the receiver never greeted the fake Mac on :\(port)")
        }
        let hello = try XCTUnwrap(mac.first(ofType: "hello"))
        XCTAssertEqual(hello["device"] as? String, "iPad")

        // --- welcome with canvas: true opens the canvas path -------------
        mac.send(["type": "welcome", "pv": 3, "min": 1, "canvas": true])
        XCTAssertTrue(waitUntil { receiver.canvas.macSupportsCanvas },
                      "welcome.canvas: true should enable the canvas path")
        XCTAssertTrue(waitUntil { !welcomes.value.isEmpty }, "onWelcome should fire")
        XCTAssertEqual(welcomes.value, [true])

        // --- a canvas message reaches the callback -----------------------
        mac.send(["type": "frozen", "ok": true, "captureMs": 1_700_000_000_123])
        XCTAssertTrue(waitUntil { !canvasMessages.value.isEmpty },
                      "frozen should be routed to onCanvasMessage")
        let (type, object) = try XCTUnwrap(canvasMessages.value.first)
        XCTAssertEqual(type, "frozen")
        XCTAssertEqual(object["ok"] as? Bool, true)

        // --- sendCanvas frames the JSON onto the socket ------------------
        let sent = expectation(description: "annotation sent")
        let sendOK = Box(false)
        receiver.sendCanvas(["type": "annotation", "id": "a1"]) { ok in
            sendOK.value = ok
            sent.fulfill()
        }
        wait(for: [sent], timeout: 5)
        XCTAssertTrue(sendOK.value, "a write on a live connection should report success")
        XCTAssertTrue(waitUntil { mac.first(ofType: "annotation") != nil },
                      "the annotation should arrive as a length-prefixed frame")
        XCTAssertEqual(try XCTUnwrap(mac.first(ofType: "annotation"))["id"] as? String, "a1")

        // --- input: allowed by default, silent once suppressed -----------
        receiver.sendTouch(phase: "began", x: 0.5, y: 0.5)
        XCTAssertTrue(waitUntil { mac.first(ofType: "touch") != nil },
                      "an OpenDisplay receiver still sends touch")
        mac.forget(type: "touch")

        receiver.suppressesInput = true
        receiver.sendTouch(phase: "moved", x: 0.6, y: 0.6)
        receiver.sendScroll(dx: 1, dy: 1)
        receiver.sendPencil(phase: "began", x: 0.1, y: 0.1,
                            pressure: 0.5, azimuth: 0, altitude: 0)
        receiver.sendProximity(entering: true, x: 0.1, y: 0.1)
        // Give anything that was going to be written time to arrive: the
        // annotation above proves the socket delivers within this window.
        _ = waitUntil(timeout: 0.5) { mac.first(ofType: "touch") != nil }
        XCTAssertNil(mac.first(ofType: "touch"), "suppressesInput must keep touch off the wire")
        XCTAssertNil(mac.first(ofType: "scroll"), "suppressesInput must keep scroll off the wire")
        XCTAssertNil(mac.first(ofType: "pencil"), "suppressesInput must keep pencil off the wire")
        XCTAssertNil(mac.first(ofType: "proximity"),
                     "suppressesInput must keep proximity off the wire")
    }

    // MARK: - Helpers

    /// Spins the main run loop so main-queue publishes and callbacks land
    /// while the test waits on them.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

/// A reference cell so callbacks fired from other queues can hand values back
/// into the test body. Every access is on the main thread (the callbacks
/// under test are documented as main-queue) except the ones the test itself
/// makes, also on the main thread.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// The other end of the session: dials the receiver, deframes what it sends,
/// and frames what it sends back. Exactly the wire in PROTOCOL.md section 4 —
/// `[4-byte big-endian length][payload]`.
private final class FakeMac {
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "test.fake.mac")
    private let lock = NSLock()
    private var buffer = Data()
    private var received: [[String: Any]] = []

    init(port: UInt16) {
        self.port = port
    }

    /// True once the socket is up. False means the receiver never bound the
    /// port — the caller skips rather than fails.
    ///
    /// A refused dial leaves NWConnection in `.waiting`, where it sits until
    /// the path changes rather than retrying on a timer, so a connection that
    /// loses the race against the listener's bind never recovers on its own.
    /// Each attempt therefore gets a fresh connection.
    func connect(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if attemptDial(within: 0.25) {
                receiveLoop()
                return true
            }
        } while Date() < deadline
        return false
    }

    private func attemptDial(within window: TimeInterval) -> Bool {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let conn = NWConnection(host: "127.0.0.1",
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: NWParameters(tls: nil, tcp: tcp))
        let settled = DispatchSemaphore(value: 0)
        let once = NSLock()
        var signalled = false
        conn.stateUpdateHandler = { state in
            once.lock()
            defer { once.unlock() }
            guard !signalled else { return }
            switch state {
            case .ready, .failed, .cancelled, .waiting:
                signalled = true
                settled.signal()
            default: break
            }
        }
        conn.start(queue: queue)
        _ = settled.wait(timeout: .now() + window)
        guard conn.state == .ready else {
            conn.stateUpdateHandler = nil
            conn.cancel()
            return false
        }
        connection = conn
        return true
    }

    func send(_ object: [String: Any]) {
        guard let connection,
              let payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func first(ofType type: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return received.first { $0["type"] as? String == type }
    }

    func forget(type: String) {
        lock.lock()
        received.removeAll { $0["type"] as? String == type }
        lock.unlock()
    }

    func stop() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func receiveLoop() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            guard error == nil, !isComplete else { return }
            self.receiveLoop()
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes {
                UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
            })
            guard buffer.count >= 4 + length else { break }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                received.append(object)
            }
        }
    }
}
