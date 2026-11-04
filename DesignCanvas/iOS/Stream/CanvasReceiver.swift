// The iPad's end of the link: listen, adopt the Mac that says hello, show its
// mirror, and carry the canvas messages both ways.
//
// The iPad listens and the Mac dials, on every transport: usbmuxd can only
// open connections toward the device, and one code path then serves USB and
// WiFi alike. Bonjour advertises the listener for WiFi; a USB dial arrives
// through usbmuxd from loopback.
//
// No UIKit here, only Foundation, Network, AVFoundation and VideoToolbox, so
// the hostless macOS test bundle compiles it and can drive it over a real
// loopback socket. The app wraps it in `ReceiverController` for the scene and
// lock lifecycle.
//
// Threading: socket and decoder state live on `queue`. The freeze flag and
// the frame on screen are behind `freezeLock`, because `setFrozen` must take
// effect on the call (PRD M1) and `currentFrame()` answers synchronously.
// Published values and callbacks land on the main queue.

import AVFoundation
import Combine
import CoreMedia
import Foundation
import Network
import VideoToolbox

final class CanvasReceiver: ObservableObject {

    struct Configuration {
        var port: UInt16 = CanvasWire.port
        /// Nil advertises nothing (tests); the app advertises `_designcanvas._tcp`.
        var serviceType: String? = CanvasWire.serviceType
        var installID: String
        /// "iPad" or "iPhone".
        var deviceKind: String
        /// The name the Mac shows, and the Bonjour service name.
        var name: String
    }

    @Published private(set) var status = "Starting…"
    /// A Mac said hello and this receiver adopted it.
    @Published private(set) var connected = false
    @Published private(set) var macName: String?
    @Published private(set) var videoSize = CGSize.zero
    @Published private(set) var fps = 0
    @Published private(set) var mbps = 0.0
    @Published private(set) var rttMs: Double?
    /// "USB" or "WiFi", for the connection screen.
    @Published private(set) var transport = "—"

    /// The Mac's hello, once per adopted connection. Main queue.
    var onMacHello: ((HelloMessage) -> Void)?
    /// A canvas message from the Mac (anything the link does not handle
    /// itself). Main queue.
    var onMessage: ((WireMessage) -> Void)?
    /// The listener is up, with the port it got (tests listen on port 0).
    var onListening: ((UInt16) -> Void)?

    let displayLayer: AVSampleBufferDisplayLayer

    private var configuration: Configuration
    private let queue = DispatchQueue(label: "designcanvas.receiver", qos: .userInteractive)

    // Queue only.
    private var listener: NWListener?
    private var listenerHealthy = false
    private var candidates: [Peer] = []
    private var session: Peer?
    private var timer: DispatchSourceTimer?
    private var renderingPaused = false
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var lastKeyframeRequest = Date.distantPast
    private var framesThisWindow = 0
    private var bytesThisWindow = 0
    private var windowStart = Date()

    private let freezeLock = NSLock()
    private var frozen = false                 // freezeLock
    private var shownFrame: UInt64?            // freezeLock

    /// One connection, from accept to close.
    private final class Peer {
        let connection: NWConnection
        let transport: String
        var reader = FrameReader()
        let acceptedAt = Date()
        var lastReceived = Date()
        /// Frames shaped like the old OpenDisplay-based wire (JSON right after
        /// the length): a Mac app that predates this one.
        var sawLegacyFrame = false

        init(connection: NWConnection) {
            self.connection = connection
            let remote = String(describing: connection.endpoint)
            // usbmuxd delivers cable connections from loopback.
            transport = remote.hasPrefix("127.0.0.1") || remote.hasPrefix("::1")
                || remote.hasPrefix("localhost") ? "USB" : "WiFi"
        }
    }

    init(configuration: Configuration, displayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer()) {
        self.configuration = configuration
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
    }

    // MARK: - Lifecycle

    func start() {
        queue.async {
            self.startListener()
            self.armTimer()
        }
    }

    /// Leave for good: tell a connected Mac, drop everything, stop listening.
    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.candidates.forEach { $0.connection.cancel() }
            self.candidates.removeAll()
        }
        close(saying: .quit, status: "Stopped", completion: completion)
    }

    /// Recreate the listener if it is not healthy: iOS may have torn it down
    /// while the app was suspended, and `enterSleep` takes it down on purpose.
    func ensureListening() {
        queue.async {
            guard !self.listenerHealthy else { return }
            Log.info("receiver: listener not healthy — restarting")
            self.restartListener()
        }
    }

    /// The device locked: nobody can see the mirror, so tell the Mac and stop
    /// accepting connections until the app is active again.
    func enterSleep(completion: (() -> Void)? = nil) {
        close(saying: .sleep, status: "Asleep — resumes on wake", completion: completion)
    }

    /// The app is being quit.
    func shutDown(completion: (() -> Void)? = nil) {
        close(saying: .quit, status: "Closed", completion: completion)
    }

    /// While the app lingers in the background the session stays up but
    /// nothing is decoded: hardware decode fails off-screen. Resuming asks
    /// the Mac for a keyframe so the picture is back at once.
    func setRenderingPaused(_ paused: Bool) {
        queue.async {
            guard paused != self.renderingPaused else { return }
            self.renderingPaused = paused
            Log.info(paused ? "receiver: rendering paused (backgrounded)" : "receiver: rendering resumed")
            if !paused {
                self.displayLayer.flush()
                self.requestKeyframe(force: true)
            }
        }
    }

    func setServiceName(_ name: String) {
        queue.async {
            guard name != self.configuration.name else { return }
            self.configuration.name = name
            if let listener = self.listener, let service = self.advertisedService {
                listener.service = service
                Log.info("receiver: re-advertising as \"\(name)\"")
            }
        }
    }

    // MARK: - Draw Mode

    /// Hold the picture on the frame that is on screen, or release it.
    /// Freezing takes effect on this call: every frame parsed after it is
    /// dropped before the display layer. Thawing drops what queued behind the
    /// freeze and asks for a keyframe; `flush()` leaves the shown image alone,
    /// so the held frame stays up until a live one replaces it.
    func setFrozen(_ value: Bool) {
        freezeLock.lock()
        let changed = value != frozen
        frozen = value
        freezeLock.unlock()
        guard changed, !value else { return }
        queue.async {
            self.displayLayer.flush()
            self.requestKeyframe(force: true)
        }
    }

    /// The number of the frame on screen: what a `freeze` names. Nil until a
    /// frame of this connection has been shown.
    func currentFrame() -> UInt64? {
        freezeLock.lock()
        defer { freezeLock.unlock() }
        return shownFrame
    }

    /// Puts a message on the wire. The completion (main queue) is true only
    /// once the socket write completed: there is no ack for canvas messages,
    /// so that is what "sent" means (plan ruling 5).
    func send(_ type: String, _ object: [String: Any], attachment: Data = Data(),
              completion: ((Bool) -> Void)? = nil) {
        let deliver: (Bool) -> Void = { ok in
            guard let completion else { return }
            DispatchQueue.main.async { completion(ok) }
        }
        guard let frame = WireCodec.message(type, object, attachment: attachment) else {
            Log.info("receiver: \(type) could not be framed")
            deliver(false)
            return
        }
        queue.async {
            guard let connection = self.session?.connection else {
                deliver(false)
                return
            }
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { Log.info("receiver: send of \(type) failed (\(error))") }
                deliver(error == nil)
            })
        }
    }

    // MARK: - Listening (queue)

    private var advertisedService: NWListener.Service? {
        guard let serviceType = configuration.serviceType else { return nil }
        var txt = NWTXTRecord()
        txt[CanvasWire.txtIDKey] = configuration.installID
        txt[CanvasWire.txtVersionKey] = String(CanvasWire.version)
        return NWListener.Service(name: configuration.name, type: serviceType, domain: nil, txtRecord: txt)
    }

    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = .interactiveVideo
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: configuration.port) ?? .any)
        } catch {
            setStatus("Could not listen: \(error.localizedDescription)")
            return
        }
        listener.service = advertisedService
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                self.listenerHealthy = true
                if self.session == nil { self.setStatus("Waiting for your Mac") }
                if let port = listener.port?.rawValue, let onListening = self.onListening {
                    DispatchQueue.main.async { onListening(port) }
                }
            case .failed(let error):
                Log.info("receiver: listener failed (\(error)) — restarting in 1 s")
                self.listenerHealthy = false
                self.queue.asyncAfter(deadline: .now() + 1) { self.restartListener() }
            case .cancelled:
                self.listenerHealthy = false
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        listenerHealthy = false
        startListener()
    }

    /// A newcomer is a candidate until it says hello as a Mac. A Bonjour dial
    /// races IPv4 and IPv6 and both handshakes can complete; the loser never
    /// speaks, so waiting for the hello is what keeps it from evicting the
    /// winner — or a live session.
    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection: connection)
        candidates.append(peer)
        Log.info("receiver: connection from \(connection.endpoint) (\(peer.transport))")
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            if case .failed = state { self.lost(peer, reason: "connection failed") }
        }
        connection.start(queue: queue)
        receive(peer)
    }

    // MARK: - Reading (queue)

    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer, self.isTracked(peer) else { return }
            if let data, !data.isEmpty {
                peer.lastReceived = Date()
                if peer === self.session { self.bytesThisWindow += data.count }
                peer.reader.append(data)
                do {
                    while let frame = try peer.reader.next() {
                        self.handle(frame, from: peer)
                        guard self.isTracked(peer) else { return }
                    }
                } catch {
                    self.lost(peer, reason: "unreadable frame (\(error))")
                    return
                }
            }
            if let error {
                self.lost(peer, reason: "receive failed (\(error))")
                return
            }
            if isComplete {
                self.lost(peer, reason: "the Mac closed the connection")
                return
            }
            self.receive(peer)
        }
    }

    private func isTracked(_ peer: Peer) -> Bool {
        peer === session || candidates.contains { $0 === peer }
    }

    private func handle(_ frame: RawFrame, from peer: Peer) {
        switch FrameKind(rawValue: frame.kind) {
        case .video:
            guard peer === session else { return }
            do {
                show(try VideoPacket(body: frame.body))
            } catch {
                Log.info("receiver: unreadable video frame — asking for a keyframe")
                requestKeyframe(force: false)
            }
        case .message:
            let message: WireMessage
            do {
                message = try WireCodec.message(from: frame.body)
            } catch {
                Log.info("receiver: unreadable message (\(error)) — ignored")
                return
            }
            if peer === session {
                handleSessionMessage(message)
            } else {
                handleCandidateMessage(message, from: peer)
            }
        case nil:
            if frame.kind == UInt8(ascii: "{") { peer.sawLegacyFrame = true }
        }
    }

    private func handleCandidateMessage(_ message: WireMessage, from peer: Peer) {
        guard message.type == CanvasWire.hello else { return }
        guard let hello = HelloMessage(json: message.object), hello.role == .mac else {
            lost(peer, reason: "the peer's hello was not a Mac's")
            return
        }
        guard hello.version == CanvasWire.version else {
            Log.info("receiver: \(hello.name ?? "a Mac") speaks wire version \(hello.version), this \(configuration.deviceKind) \(CanvasWire.version)")
            sendLinkMessage(CanvasWire.bye, ByeMessage(reason: .version).json, on: peer.connection)
            candidates.removeAll { $0 === peer }
            let connection = peer.connection
            queue.asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
            setStatus(hello.version > CanvasWire.version
                      ? "\(hello.name ?? "Your Mac") has a newer Design Canvas — update this app"
                      : "\(hello.name ?? "Your Mac") has an older Design Canvas — update it there")
            return
        }
        if let current = session, !Self.mayReplace(current: current.transport, with: peer.transport) {
            Log.info("receiver: \(hello.name ?? "a Mac") said hello over WiFi while a cabled Mac is connected — turned away")
            sendLinkMessage(CanvasWire.bye, ByeMessage(reason: .inUse).json, on: peer.connection)
            candidates.removeAll { $0 === peer }
            let connection = peer.connection
            queue.asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
            return
        }
        adopt(peer, hello: hello)
    }

    /// Whether a newcomer may take the session from the connection it has.
    /// Nothing on the link is authenticated yet, and anything on the LAN can
    /// dial the iPad and say hello as a Mac; a cable at least is physical. So
    /// a WiFi hello never evicts a session over USB. The real fix is a pairing
    /// step (spec/TODOS.md, encrypted WiFi transport).
    static func mayReplace(current: String, with newcomer: String) -> Bool {
        !(current == "USB" && newcomer != "USB")
    }

    /// Make `peer` the session, replacing any other.
    private func adopt(_ peer: Peer, hello: HelloMessage) {
        candidates.removeAll { $0 === peer }
        if let previous = session {
            Log.info("receiver: a newer connection replaces the session")
            sendLinkMessage(CanvasWire.bye, ByeMessage(reason: .replaced).json, on: previous.connection)
            let connection = previous.connection
            queue.asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
        }
        session = peer
        resetStream()
        let me = HelloMessage(version: CanvasWire.version, role: .ipad, name: configuration.name,
                              installID: configuration.installID, device: configuration.deviceKind)
        sendLinkMessage(CanvasWire.hello, me.json, on: peer.connection)
        Log.info("receiver: adopted \(hello.name ?? "a Mac") over \(peer.transport)")
        let transport = peer.transport
        let name = hello.name
        DispatchQueue.main.async {
            self.connected = true
            self.macName = name
            self.transport = transport
            self.rttMs = nil
            self.onMacHello?(hello)
        }
        setStatus(name.map { "Connected to \($0)" } ?? "Connected")
    }

    private func handleSessionMessage(_ message: WireMessage) {
        switch message.type {
        case CanvasWire.hello:
            break
        case CanvasWire.ping:
            sendLinkMessage(CanvasWire.pong, ["t": message.object["t"] ?? 0])
        case CanvasWire.pong:
            if let sent = (message.object["t"] as? NSNumber)?.doubleValue {
                let rtt = Date().timeIntervalSince1970 * 1000 - sent
                if rtt >= 0, rtt < 10_000 {
                    DispatchQueue.main.async { self.rttMs = rtt }
                }
            }
        case CanvasWire.bye:
            let bye = ByeMessage(json: message.object)
            guard let session else { return }
            Log.info("receiver: the Mac said bye (\(bye.reason.rawValue))")
            endSession(session)
            setStatus(bye.reason == .version
                      ? "Your Mac has a different Design Canvas version — update the older one"
                      : "Disconnected by the Mac")
        default:
            guard let onMessage else { return }
            DispatchQueue.main.async { onMessage(message) }
        }
    }

    /// A tracked connection ended.
    private func lost(_ peer: Peer, reason: String) {
        if peer === session {
            Log.info("receiver: session ended — \(reason)")
            endSession(peer)
            setStatus("Waiting for your Mac")
        } else if let index = candidates.firstIndex(where: { $0 === peer }) {
            candidates.remove(at: index)
            peer.connection.cancel()
            if peer.sawLegacyFrame {
                setStatus("A Mac with an older Design Canvas tried to connect — update it there")
            }
        }
    }

    private func endSession(_ peer: Peer) {
        guard peer === session else { return }
        session = nil
        peer.connection.cancel()
        freezeLock.lock()
        shownFrame = nil
        freezeLock.unlock()
        DispatchQueue.main.async {
            self.connected = false
            self.macName = nil
            self.rttMs = nil
            self.fps = 0
            self.mbps = 0
            // The next Mac's first keyframe says how big its stream is.
            self.videoSize = .zero
        }
    }

    private func close(saying reason: ByeMessage.Reason, status text: String, completion: (() -> Void)?) {
        queue.async {
            var finished = false
            let finish = { [weak self] in
                guard let self, !finished else { return }
                finished = true
                if let session = self.session { self.endSession(session) }
                self.listener?.cancel()
                self.listener = nil
                self.listenerHealthy = false
                self.setStatus(text)
                completion?()
            }
            guard let connection = self.session?.connection,
                  let frame = WireCodec.message(CanvasWire.bye, ByeMessage(reason: reason).json) else {
                finish()
                return
            }
            Log.info("receiver: closing — telling the Mac (\(reason.rawValue))")
            connection.send(content: frame, completion: .contentProcessed { _ in
                self.queue.async { finish() }
            })
            // The send may never complete on a dying link.
            self.queue.asyncAfter(deadline: .now() + 1) { finish() }
        }
    }

    private func sendLinkMessage(_ type: String, _ object: [String: Any], on connection: NWConnection? = nil) {
        guard let connection = connection ?? session?.connection,
              let frame = WireCodec.message(type, object) else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - Liveness (queue)

    private func armTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + CanvasWire.pingInterval, repeating: CanvasWire.pingInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        for candidate in candidates where now.timeIntervalSince(candidate.acceptedAt) > CanvasWire.silenceTimeout {
            lost(candidate, reason: "no hello")
        }
        guard let session else { return }
        if now.timeIntervalSince(session.lastReceived) > CanvasWire.silenceTimeout {
            lost(session, reason: "nothing from the Mac for \(Int(CanvasWire.silenceTimeout)) s")
            return
        }
        sendLinkMessage(CanvasWire.ping, ["t": (now.timeIntervalSince1970 * 1000).rounded()])
        let elapsed = now.timeIntervalSince(windowStart)
        if elapsed > 0 {
            let fps = Int((Double(framesThisWindow) / elapsed).rounded())
            let mbps = Double(bytesThisWindow) * 8 / elapsed / 1_000_000
            DispatchQueue.main.async {
                if self.fps != fps { self.fps = fps }
                self.mbps = mbps
            }
        }
        framesThisWindow = 0
        bytesThisWindow = 0
        windowStart = now
    }

    // MARK: - Video (queue)

    private func resetStream() {
        formatDescription = nil
        parameterSets = []
        displayLayer.flush()
        framesThisWindow = 0
        bytesThisWindow = 0
        windowStart = Date()
        freezeLock.lock()
        shownFrame = nil
        freezeLock.unlock()
    }

    private func show(_ packet: VideoPacket) {
        if !packet.parameterSets.isEmpty, packet.parameterSets != parameterSets {
            parameterSets = packet.parameterSets
            formatDescription = Self.formatDescription(parameterSets: packet.parameterSets)
            displayLayer.flush()
            if let formatDescription {
                let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
                Log.info("receiver: stream is \(dims.width)x\(dims.height)")
                DispatchQueue.main.async {
                    self.videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
                }
            } else {
                Log.info("receiver: the stream's parameter sets were refused")
            }
        }
        guard let formatDescription else {
            // Joined between keyframes.
            requestKeyframe(force: false)
            return
        }
        guard !renderingPaused else { return }
        freezeLock.lock()
        let held = frozen
        freezeLock.unlock()
        guard !held else { return }
        guard packet.sampleIsWellFormed, let sample = Self.sampleBuffer(packet.sample, format: formatDescription) else {
            requestKeyframe(force: false)
            return
        }
        if displayLayer.status == .failed {
            Log.info("receiver: display layer failed (\(String(describing: displayLayer.error))) — flushing")
            displayLayer.flush()
            requestKeyframe(force: false)
            if !packet.isKeyframe { return }
        }
        displayLayer.enqueue(sample)
        // On its way to glass, so it is the frame a freeze would name.
        freezeLock.lock()
        shownFrame = packet.frame
        freezeLock.unlock()
        framesThisWindow += 1
    }

    /// At most one a second unless `force`: a decoder that lost sync stays
    /// lost until the keyframe lands, and every frame in between would ask.
    private func requestKeyframe(force: Bool) {
        guard session != nil else { return }
        guard force || Date().timeIntervalSince(lastKeyframeRequest) > 1 else { return }
        lastKeyframeRequest = Date()
        sendLinkMessage(CanvasWire.keyframe, [:])
    }

    private static func formatDescription(parameterSets: [Data]) -> CMVideoFormatDescription? {
        guard parameterSets.count >= 2, parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }
        var description: CMVideoFormatDescription?
        let status: OSStatus = withPointers(to: parameterSets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    /// Calls `body` with stable pointers to every element's bytes.
    private static func withPointers<R>(to sets: [Data],
                                        _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) }, sets.map(\.count))
    }

    /// A ready sample buffer that owns a copy of `sample`, marked to display
    /// at once rather than on a schedule.
    private static func sampleBuffer(_ sample: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: sample.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = sample.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: sample.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var buffer: CMSampleBuffer?
        var size = sample.count
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr,
              let buffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buffer
    }

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        Log.info("receiver: status — \(text)")
        DispatchQueue.main.async {
            if self.status != text { self.status = text }
        }
    }
}
