import CoreVideo
import Network
import XCTest

/// Both ends of the link over a real loopback socket: the Mac's `MirrorLink`
/// dials the iPad's `CanvasReceiver`, exactly as it would over WiFi, with no
/// device and no screen capture. What only hardware can show (usbmuxd, the
/// display layer on glass) is the device checklist's job.
final class LinkLoopbackTests: XCTestCase {

    private final class RecordingDelegate: MirrorLinkDelegate {
        private let lock = NSLock()
        private var storedPhases: [LinkPhase] = []
        private var storedHellos: [HelloMessage] = []
        private var storedMessages: [WireMessage] = []
        private var storedDrops = 0
        private var storedLatest: CapturedFrame?

        var phases: [LinkPhase] { lock.withLock { storedPhases } }
        var phase: LinkPhase? { lock.withLock { storedPhases.last } }
        var hellos: [HelloMessage] { lock.withLock { storedHellos } }
        var messages: [WireMessage] { lock.withLock { storedMessages } }
        var drops: Int { lock.withLock { storedDrops } }
        var latest: CapturedFrame? {
            get { lock.withLock { storedLatest } }
            set { lock.withLock { storedLatest = newValue } }
        }

        func link(_ link: MirrorLink, didChangePhase phase: LinkPhase) {
            lock.withLock { storedPhases.append(phase) }
        }

        func link(_ link: MirrorLink, didHello peer: HelloMessage) {
            lock.withLock { storedHellos.append(peer) }
        }

        func link(_ link: MirrorLink, didReceive message: WireMessage) {
            lock.withLock { storedMessages.append(message) }
        }

        func linkDidDrop(_ link: MirrorLink) {
            lock.withLock { storedDrops += 1 }
        }

        func latestFrame(for link: MirrorLink) -> CapturedFrame? {
            latest
        }
    }

    private var receivers: [CanvasReceiver] = []
    private var links: [MirrorLink] = []
    private let queue = DispatchQueue(label: "test.stream")

    override func tearDown() {
        links.forEach { $0.stop() }
        receivers.forEach { $0.stop() }
        links = []
        receivers = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// A receiver listening on a free port, and that port.
    private func startReceiver(name: String = "Test iPad") throws -> (CanvasReceiver, UInt16) {
        let receiver = CanvasReceiver(configuration: .init(port: 0, serviceType: nil, installID: "INSTALL-1",
                                                           deviceKind: "iPad", name: name))
        var port: UInt16?
        receiver.onListening = { port = $0 }
        receiver.start()
        receivers.append(receiver)
        guard waitUntil("the receiver to listen", { port != nil }), let port else {
            throw XCTSkip("the receiver never listened")
        }
        return (receiver, port)
    }

    private func startLink(to port: UInt16, macName: String = "Test Mac",
                           delegate: RecordingDelegate, frames: CleanFrameStore = CleanFrameStore()) -> MirrorLink {
        let link = MirrorLink(queue: queue, macName: macName, frames: frames, quality: .fast)
        link.delegate = delegate
        links.append(link)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        link.start(paths: LinkPaths(usbUDID: nil, wifi: endpoint))
        return link
    }

    private func isStreaming(_ phase: LinkPhase?) -> Bool {
        if case .streaming? = phase { return true }
        return false
    }

    private func makeFrame(number: UInt64, luma: UInt8, width: Int = 320, height: Int = 240) -> CapturedFrame? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, Int32(plane == 0 ? luma : 128), bytes)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return CapturedFrame(number: number, pixelBuffer: buffer, capturedAt: Date())
    }

    // MARK: - Handshake

    func test_theMacDialsSaysHelloAndBothEndsKnowEachOther() throws {
        let (receiver, port) = try startReceiver()
        var macHellos: [HelloMessage] = []
        receiver.onMacHello = { macHellos.append($0) }
        let delegate = RecordingDelegate()
        _ = startLink(to: port, delegate: delegate)

        waitUntil("the link to stream") { isStreaming(delegate.phase) }
        waitUntil("the receiver to adopt the Mac") { receiver.connected && receiver.macName == "Test Mac" }
        XCTAssertEqual(delegate.hellos.first?.installID, "INSTALL-1")
        XCTAssertEqual(delegate.hellos.first?.name, "Test iPad")
        XCTAssertEqual(delegate.hellos.first?.device, "iPad")
        XCTAssertEqual(macHellos.first?.role, .mac)
        // Dial, connect, hello: the menu sees each step.
        XCTAssertTrue(delegate.phases.contains(.dialing(.wifi)))
        XCTAssertTrue(delegate.phases.contains(.handshaking(.wifi)))
    }

    // MARK: - Messages

    /// A sketch rides as raw bytes beside its JSON: no base64, nothing to
    /// shrink, and big enough to arrive in many reads.
    func test_aSketchArrivesAtTheMacByteForByte() throws {
        let (receiver, port) = try startReceiver()
        let delegate = RecordingDelegate()
        _ = startLink(to: port, delegate: delegate)
        guard waitUntil("the handshake", { isStreaming(delegate.phase) && receiver.connected }) else { return }

        let sketch = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var sent: Bool?
        receiver.send(CanvasWire.annotation, ["t": 1234.5, "viewport": ["w": 10, "h": 10, "scale": 2]],
                      attachment: sketch) { sent = $0 }
        waitUntil("the send to complete") { sent != nil }
        XCTAssertEqual(sent, true)
        waitUntil("the Mac to receive it", timeout: 10) { delegate.messages.contains { $0.type == CanvasWire.annotation } }
        let message = delegate.messages.first { $0.type == CanvasWire.annotation }
        XCTAssertEqual(message?.attachment, sketch)
        XCTAssertEqual((message?.object["t"] as? NSNumber)?.doubleValue, 1234.5)
    }

    func test_aMessageFromTheMacReachesTheIPadModel() throws {
        let (receiver, port) = try startReceiver()
        var received: [WireMessage] = []
        receiver.onMessage = { received.append($0) }
        let delegate = RecordingDelegate()
        let link = startLink(to: port, delegate: delegate)
        guard waitUntil("the handshake", { isStreaming(delegate.phase) && receiver.connected }) else { return }

        XCTAssertTrue(link.send(CanvasWire.status, StatusMessage(channel: .attached, project: "site").json))
        waitUntil("the status to arrive") { received.contains { $0.type == CanvasWire.status } }
        let status = received.first { $0.type == CanvasWire.status }.flatMap { StatusMessage(json: $0.object) }
        XCTAssertEqual(status, StatusMessage(channel: .attached, project: "site"))
    }

    // MARK: - Video

    /// The frame number the Mac stamps is the one the iPad reports on screen,
    /// and the clean original is in the Mac's ring under it: that pairing is
    /// what a freeze rests on.
    func test_aFrameReachesTheScreenUnderItsNumber_andTheMacKeepsItsCleanCopy() throws {
        guard VideoEncoder(width: 320, height: 240, bitrate: 1_000_000) != nil else {
            throw XCTSkip("no H.264 encoder on this machine")
        }
        let (receiver, port) = try startReceiver()
        let delegate = RecordingDelegate()
        delegate.latest = makeFrame(number: 41, luma: 60)
        let frames = CleanFrameStore()
        _ = startLink(to: port, delegate: delegate, frames: frames)

        waitUntil("frame 41 on screen", timeout: 10) { receiver.currentFrame() == 41 }
        XCTAssertNotNil(frames.cleanFrame(41))
        waitUntil("the stream size") { receiver.videoSize == CGSize(width: 320, height: 240) }
    }

    /// Draw Mode holds the picture: nothing replaces it until the thaw, which
    /// asks for a keyframe of whatever is newest.
    func test_aFrozenScreenKeepsItsFrame_andTheThawCatchesUp() throws {
        guard VideoEncoder(width: 320, height: 240, bitrate: 1_000_000) != nil else {
            throw XCTSkip("no H.264 encoder on this machine")
        }
        let (receiver, port) = try startReceiver()
        let delegate = RecordingDelegate()
        delegate.latest = makeFrame(number: 1, luma: 40)
        let link = startLink(to: port, delegate: delegate)
        guard waitUntil("frame 1 on screen", timeout: 10, { receiver.currentFrame() == 1 }) else { return }

        receiver.setFrozen(true)
        let newer = try XCTUnwrap(makeFrame(number: 2, luma: 200))
        delegate.latest = newer
        queue.async { link.offer(newer) }
        // Long enough for the frame to cross; it must not be shown.
        let settle = Date().addingTimeInterval(0.5)
        while Date() < settle { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(receiver.currentFrame(), 1)

        receiver.setFrozen(false)
        waitUntil("the thaw to show the newest frame", timeout: 10) { receiver.currentFrame() == 2 }
    }

    // MARK: - Leaving

    func test_quittingTheAppSaysBye_andTheMacWaitsForItToReturn() throws {
        let (receiver, port) = try startReceiver()
        let delegate = RecordingDelegate()
        _ = startLink(to: port, delegate: delegate)
        guard waitUntil("the handshake", { isStreaming(delegate.phase) && receiver.connected }) else { return }

        receiver.shutDown()
        waitUntil("the link to notice the bye") { delegate.drops == 1 }
        waitUntil("the link to wait for the app") { delegate.phase == .retrying(.appNotOpen) }
    }

    /// One iPad, two Macs: the newer hello wins, and the Mac it replaced stops
    /// dialing instead of taking the iPad straight back.
    func test_aSecondMacTakesOver_andTheFirstStandsAside() throws {
        let (receiver, port) = try startReceiver()
        let first = RecordingDelegate()
        _ = startLink(to: port, macName: "First Mac", delegate: first)
        guard waitUntil("the first Mac", { isStreaming(first.phase) && receiver.macName == "First Mac" }) else { return }

        let second = RecordingDelegate()
        _ = startLink(to: port, macName: "Second Mac", delegate: second)
        waitUntil("the second Mac to stream") { isStreaming(second.phase) }
        waitUntil("the receiver to show the second Mac") { receiver.macName == "Second Mac" }
        waitUntil("the first Mac to stand aside") { first.phase == .yielded }
    }

    /// Both apps ship together, so there is no negotiation: a Mac with another
    /// wire version is told so and turned away, and the iPad says which side
    /// to update.
    func test_aMacSpeakingAnotherVersionIsTurnedAway() throws {
        let (receiver, port) = try startReceiver()
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        let lock = NSLock()
        var reader = FrameReader()
        var bye: ByeMessage?
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                lock.withLock {
                    if let data { reader.append(data) }
                    while let frame = try? reader.next() {
                        if let message = try? WireCodec.message(from: frame.body), message.type == CanvasWire.bye {
                            bye = ByeMessage(json: message.object)
                        }
                    }
                }
                if error == nil, !isComplete { read() }
            }
        }
        connection.start(queue: queue)
        read()
        let hello = HelloMessage(version: CanvasWire.version + 1, role: .mac, name: "Future Mac")
        connection.send(content: WireCodec.message(CanvasWire.hello, hello.json), completion: .contentProcessed { _ in })

        waitUntil("the bye") { lock.withLock { bye } != nil }
        XCTAssertEqual(lock.withLock { bye }?.reason, .version)
        XCTAssertFalse(receiver.connected)
        waitUntil("the status to name the fix") { receiver.status.contains("update this app") }
    }
}
