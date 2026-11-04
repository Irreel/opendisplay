// One iPad, from the Mac's side: dial it, say hello, stream the mirror to it,
// carry its canvas messages, and dial again whenever the connection goes.
//
// A link lives as long as the Mac means to serve that iPad, across any number
// of connections. Moving between USB and WiFi is just another reconnect: the
// iPad adopts whichever connection says hello last, and there is no virtual
// display or window arrangement on the Mac that a reconnect could disturb.
//
// Everything here runs on the stream queue the engine hands in; the public
// methods hop onto it.

import Foundation
import Network

enum LinkTransport: String, Equatable {
    case usb = "USB"
    case wifi = "WiFi"
}

/// Where an iPad can be reached right now. USB wins whenever it is there.
struct LinkPaths: Equatable {
    var usbUDID: String?
    var wifi: NWEndpoint?
    /// The install id a hello over WiFi must name, or nil when there is none
    /// to hold it to (the user clicked a service that advertised no id). The
    /// id is all that ties a service to the iPad the user trusted.
    var wifiInstallID: String?

    static let none = LinkPaths()

    var best: (LinkTransport, Path)? {
        if let usbUDID { return (.usb, .usb(udid: usbUDID)) }
        if let wifi { return (.wifi, .tcp(wifi)) }
        return nil
    }

    enum Path: Equatable {
        case usb(udid: String)
        case tcp(NWEndpoint)
    }
}

enum LinkPhase: Equatable {
    /// Nowhere to dial: the iPad is not attached or advertised.
    case idle
    case dialing(LinkTransport)
    /// Connected; waiting for the iPad's hello.
    case handshaking(LinkTransport)
    case streaming(LinkTransport)
    /// Between attempts, with why the last one ended.
    case retrying(RetryReason)
    /// Another Mac took this iPad over. No redial until something changes.
    case yielded
    /// The iPad speaks a different wire version.
    case versionMismatch(theirs: Int)
    case stopped
}

enum RetryReason: Equatable {
    /// The iPad is reachable but nothing listens: the app is not open.
    case appNotOpen
    /// The iPad said it was going to sleep.
    case asleep
    /// Anything else, as the log line puts it.
    case network(String)

    var text: String {
        switch self {
        case .appNotOpen: return "waiting for the Design Canvas app"
        case .asleep: return "the iPad is asleep"
        case .network(let detail): return detail
        }
    }
}

/// What the link reports about itself, on the stream queue.
protocol MirrorLinkDelegate: AnyObject {
    func link(_ link: MirrorLink, didChangePhase phase: LinkPhase)
    /// The iPad said hello: streaming starts now.
    func link(_ link: MirrorLink, didHello peer: HelloMessage)
    /// A canvas message (anything that is not the link's own business).
    func link(_ link: MirrorLink, didReceive message: WireMessage)
    /// The connection that said hello is gone.
    func linkDidDrop(_ link: MirrorLink)
    /// The newest captured frame, for a keyframe the screen gives no reason to send.
    func latestFrame(for link: MirrorLink) -> CapturedFrame?
}

/// `@unchecked Sendable`: every mutable field is confined to the stream queue.
final class MirrorLink: CanvasOutbound, @unchecked Sendable {

    let id: String
    weak var delegate: MirrorLinkDelegate?

    private let queue: DispatchQueue
    private let hello: HelloMessage
    private let frames: CleanFrameStore
    private let quality: StreamQuality
    private let port: UInt16

    // All below: stream queue only.
    private var paths = LinkPaths.none
    private(set) var phase: LinkPhase = .idle {
        didSet { if phase != oldValue { delegate?.link(self, didChangePhase: phase) } }
    }
    private(set) var peer: HelloMessage?
    private var connection: NWConnection?
    private var transport: LinkTransport?
    /// Bumped per connection: anything still in flight for an older one (a
    /// dial, an encode, a send) checks it and lets go.
    private var generation = 0
    private var reader = FrameReader()
    private var lastReceived = Date()
    private var connectedAt = Date()
    /// The peer sent frames shaped like the protocol Design Canvas used before
    /// it had its own (JSON straight after the length): an iPad app that
    /// predates this one.
    private var sawLegacyFrame = false
    private var timer: DispatchSourceTimer?
    private var attempts = 0
    private var started = false
    /// The iPad said it was going to sleep, and has not said hello since. A
    /// locked iPad refuses dials exactly like a closed app, so this is what
    /// keeps the menu saying "asleep" until it wakes.
    private var peerAsleep = false

    // Video: at most one encode and `maxVideoInFlight` sends at a time. A
    // frame that arrives while the pipe is full waits in `pending`, and a
    // newer one replaces it — the iPad only ever needs the latest picture,
    // and a static screen must still end up showing its last change.
    private var encoder: VideoEncoder?
    private var encoding = false
    private var videoInFlight = 0
    private let maxVideoInFlight = 3
    private var pending: CapturedFrame?
    private var needsKeyframe = true
    private var encodeFailures = LogThrottle(interval: 5)

    init(id: String = UUID().uuidString, queue: DispatchQueue, macName: String?,
         frames: CleanFrameStore, quality: StreamQuality = .stored, port: UInt16 = CanvasWire.port) {
        self.id = id
        self.queue = queue
        self.hello = HelloMessage(version: CanvasWire.version, role: .mac, name: macName)
        self.frames = frames
        self.quality = quality
        self.port = port
    }

    // MARK: - Control (any thread)

    func start(paths: LinkPaths) {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.paths = paths
            self.dialIfPossible()
        }
    }

    /// The engine's latest knowledge of where the iPad is. A cable plugged in
    /// under a WiFi session moves the session onto it; a path appearing while
    /// the link waits, or after another Mac took the iPad, dials at once.
    func update(paths newPaths: LinkPaths) {
        queue.async {
            guard self.started, self.phase != .stopped else { return }
            let old = self.paths
            self.paths = newPaths
            guard newPaths != old else { return }
            switch self.phase {
            case .idle, .retrying, .yielded:
                self.attempts = 0
                self.dialIfPossible()
            case .streaming(.wifi), .handshaking(.wifi), .dialing(.wifi):
                if newPaths.usbUDID != nil {
                    Log.info("link \(self.label): cable attached — moving to USB")
                    self.reconnectNow()
                }
            case .versionMismatch:
                // A replug or a re-advertisement may be the updated app.
                self.attempts = 0
                self.dialIfPossible()
            default:
                break
            }
        }
    }

    /// Dial again now, whatever the link was doing (the user asked).
    func reconnect() {
        queue.async {
            guard self.started, self.phase != .stopped else { return }
            self.reconnectNow()
        }
    }

    /// End the link for good. With `bye`, the iPad is told so it does not
    /// read the silence as a fault.
    func stop(bye: ByeMessage.Reason? = nil) {
        queue.async {
            guard self.phase != .stopped else { return }
            if let bye, let connection = self.connection,
               let frame = WireCodec.message(CanvasWire.bye, ByeMessage(reason: bye).json) {
                connection.send(content: frame, completion: .contentProcessed { _ in connection.cancel() })
                self.connection = nil
            }
            self.closeConnection()
            self.timer?.cancel()
            self.timer = nil
            self.phase = .stopped
        }
    }

    // MARK: - CanvasOutbound

    /// Encodes now and returns whether the message could be framed at all;
    /// the send itself happens on the queue and only on a link that has said
    /// hello. A message that finds the link down is dropped with a log line:
    /// the next hello resends everything a reconnecting iPad needs.
    @discardableResult
    func send(_ type: String, _ object: [String: Any], attachment: Data) -> Bool {
        guard let frame = WireCodec.message(type, object, attachment: attachment) else {
            Log.info("link: refused to send \(type) — not serialisable, or over the size limit")
            return false
        }
        queue.async {
            guard case .streaming = self.phase, let connection = self.connection else {
                Log.info("link \(self.label): \(type) dropped — not connected")
                return
            }
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
        return true
    }

    // MARK: - Video (stream queue)

    /// A new captured frame. Encoded now if the pipe has room, otherwise kept
    /// as the one to encode next.
    func offer(_ frame: CapturedFrame) {
        guard case .streaming = phase else { return }
        if encoding || videoInFlight >= maxVideoInFlight {
            pending = frame
            return
        }
        submit(frame)
    }

    private func submit(_ frame: CapturedFrame) {
        if encoder == nil || encoder?.width != frame.width || encoder?.height != frame.height {
            encoder?.invalidate()
            encoder = VideoEncoder(width: frame.width, height: frame.height, bitrate: quality.bitrate)
            needsKeyframe = true
        }
        guard let encoder else { return }
        // Kept before it is encoded, so the frame this iPad may freeze on is
        // always one the ring holds.
        frames.keep(frame.pixelBuffer, frame: frame.number, capturedAt: frame.capturedAt)
        let force = needsKeyframe
        needsKeyframe = false
        encoding = true
        let generation = self.generation
        let submitted = encoder.encode(frame, forceKeyframe: force) { [weak self] packet, status in
            self?.queue.async { self?.encoded(packet, status: status, generation: generation, wasKeyframe: force) }
        }
        if !submitted {
            encoding = false
            needsKeyframe = needsKeyframe || force
            noteEncodeFailure("submit failed")
        }
    }

    private func encoded(_ packet: VideoPacket?, status: OSStatus, generation: Int, wasKeyframe: Bool) {
        encoding = false
        guard generation == self.generation, case .streaming = phase, let connection else { return }
        if let packet {
            videoInFlight += 1
            connection.send(content: WireCodec.video(packet), completion: .contentProcessed { [weak self] _ in
                self?.queue.async {
                    guard let self, generation == self.generation else { return }
                    self.videoInFlight -= 1
                    self.drainPending()
                }
            })
        } else {
            if wasKeyframe { needsKeyframe = true }
            noteEncodeFailure("output rejected (status \(status))")
        }
        drainPending()
    }

    private func drainPending() {
        guard !encoding, videoInFlight < maxVideoInFlight, let next = pending else { return }
        pending = nil
        submit(next)
    }

    /// Re-encode the newest frame as a keyframe: a static screen sends no new
    /// frame for the forced keyframe to ride on.
    private func sendKeyframe() {
        needsKeyframe = true
        guard !encoding, pending == nil, let latest = delegate?.latestFrame(for: self) else { return }
        offer(latest)
    }

    private func noteEncodeFailure(_ detail: String) {
        if let swallowed = encodeFailures.admit(now: ProcessInfo.processInfo.systemUptime) {
            Log.info("link \(label): encode \(detail)\(swallowed > 0 ? " (\(swallowed) more since the last report)" : "")")
        }
    }

    // MARK: - Dialing (stream queue)

    private var label: String { peer?.name ?? id.prefix(8).description }

    private func dialIfPossible() {
        guard phase != .stopped else { return }
        guard let (transport, path) = paths.best else {
            phase = .idle
            return
        }
        closeConnection()
        generation += 1
        let generation = self.generation
        self.transport = transport
        phase = .dialing(transport)
        switch path {
        case .usb(let udid):
            Task { [weak self, queue, port] in
                do {
                    let connection = try await Usbmux.dial(udid: udid, port: port, queue: queue)
                    queue.async { self?.dialSucceeded(connection, generation: generation) ?? connection.cancel() }
                } catch {
                    let reason: RetryReason
                    switch error as? Usbmux.Failure {
                    case .refused: reason = .appNotOpen
                    case .noDevice: reason = .network("the iPad is not attached")
                    default: reason = .network("USB: \(error.localizedDescription)")
                    }
                    queue.async { self?.dialFailed(reason, generation: generation) }
                }
            }
        case .tcp(let endpoint):
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, generation == self.generation else { return }
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    self.dialSucceeded(connection, generation: generation)
                case .failed(let error), .waiting(let error):
                    connection.cancel()
                    let refused: Bool
                    if case .posix(let code) = error, code == .ECONNREFUSED { refused = true } else { refused = false }
                    self.dialFailed(refused ? .appNotOpen : .network("WiFi: \(error)"), generation: generation)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            // A dial to a withdrawn Bonjour service can sit in .preparing for
            // ever. A fresh connection re-resolves, so time out and try again.
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, generation == self.generation, case .dialing = self.phase else { return }
                connection.cancel()
                self.dialFailed(.network("WiFi: no answer"), generation: generation)
            }
        }
    }

    private func dialSucceeded(_ connection: NWConnection, generation: Int) {
        guard generation == self.generation, case .dialing(let transport) = phase else {
            connection.cancel()
            return
        }
        self.connection = connection
        reader = FrameReader()
        lastReceived = Date()
        connectedAt = Date()
        sawLegacyFrame = false
        phase = .handshaking(transport)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, generation == self.generation else { return }
            switch state {
            case .failed(let error):
                self.dropConnection("connection failed: \(error)")
            case .cancelled:
                break
            default:
                break
            }
        }
        if let frame = WireCodec.message(CanvasWire.hello, hello.json) {
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
        receive(on: connection, generation: generation)
        armTimer()
        Log.info("link \(label): connected over \(transport.rawValue) — waiting for the iPad's hello")
    }

    private func dialFailed(_ reason: RetryReason, generation: Int) {
        guard generation == self.generation, case .dialing = phase else { return }
        scheduleRetry(reason)
    }

    private func scheduleRetry(_ reason: RetryReason) {
        guard phase != .stopped else { return }
        closeConnection()
        guard paths.best != nil else {
            phase = .idle
            return
        }
        phase = .retrying(peerAsleep ? .asleep : reason)
        attempts += 1
        let delay = min(0.5 * pow(2, Double(min(attempts - 1, 3))), 3)
        let generation = self.generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.generation, case .retrying = self.phase else { return }
            self.dialIfPossible()
        }
    }

    private func reconnectNow() {
        attempts = 0
        let wasLive: Bool
        if case .streaming = phase { wasLive = true } else { wasLive = false }
        closeConnection()
        if wasLive { delegate?.linkDidDrop(self) }
        dialIfPossible()
    }

    /// The connection is gone (or about to be): forget it and everything that
    /// belonged to it.
    private func closeConnection() {
        generation += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        transport = nil
        encoder?.invalidate()
        encoder = nil
        encoding = false
        videoInFlight = 0
        pending = nil
        needsKeyframe = true
    }

    private func dropConnection(_ reason: String) {
        guard connection != nil else { return }
        Log.info("link \(label): \(reason)")
        let hadHello: Bool
        if case .streaming = phase { hadHello = true } else { hadHello = false }
        closeConnection()
        if hadHello { delegate?.linkDidDrop(self) }
        scheduleRetry(.network(reason))
    }

    // MARK: - Reading (stream queue)

    private func receive(on connection: NWConnection, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, generation == self.generation else { return }
            if let data, !data.isEmpty {
                // Every chunk counts as life, so a large upload that is still
                // arriving never looks like silence.
                self.lastReceived = Date()
                self.reader.append(data)
                do {
                    while let frame = try self.reader.next() {
                        self.handle(frame)
                        guard generation == self.generation else { return }
                    }
                } catch {
                    self.dropConnection("unreadable frame (\(error))")
                    return
                }
            }
            if let error {
                self.dropConnection("receive failed: \(error)")
                return
            }
            if isComplete {
                self.dropConnection("the iPad closed the connection")
                return
            }
            self.receive(on: connection, generation: generation)
        }
    }

    private func handle(_ frame: RawFrame) {
        guard frame.kind == FrameKind.message.rawValue else {
            // Nothing else flows this way. A `{` where the kind should be is
            // the old wire's JSON.
            if frame.kind == UInt8(ascii: "{") { sawLegacyFrame = true }
            return
        }
        let message: WireMessage
        do {
            message = try WireCodec.message(from: frame.body)
        } catch {
            Log.info("link \(label): unreadable message (\(error)) — ignored")
            return
        }
        switch message.type {
        case CanvasWire.hello:
            handleHello(message.object)
        case CanvasWire.ping:
            sendLinkMessage(CanvasWire.pong, ["t": message.object["t"] ?? 0])
        case CanvasWire.pong:
            break
        case CanvasWire.keyframe:
            sendKeyframe()
        case CanvasWire.bye:
            let bye = ByeMessage(json: message.object)
            Log.info("link \(label): the iPad said bye (\(bye.reason.rawValue))")
            let wasStreaming: Bool
            if case .streaming = phase { wasStreaming = true } else { wasStreaming = false }
            closeConnection()
            if wasStreaming { delegate?.linkDidDrop(self) }
            switch bye.reason {
            case .replaced, .inUse:
                phase = .yielded
            case .version:
                phase = .versionMismatch(theirs: peer?.version ?? 0)
            case .sleep, .quit:
                attempts = 0
                peerAsleep = bye.reason == .sleep
                scheduleRetry(bye.reason == .sleep ? .asleep : .appNotOpen)
            }
        default:
            guard case .streaming = phase else { return }
            delegate?.link(self, didReceive: message)
        }
    }

    private func handleHello(_ object: [String: Any]) {
        guard case .handshaking(let transport) = phase else { return }
        guard let hello = HelloMessage(json: object), hello.role == .ipad else {
            dropConnection("the peer's hello was not an iPad's")
            return
        }
        if transport == .wifi, let expected = paths.wifiInstallID, hello.installID != expected {
            Log.info("link \(label): the hello over WiFi does not name the iPad this Mac trusts there — not streaming to it")
            dropConnection("identity mismatch")
            return
        }
        guard hello.version == CanvasWire.version else {
            Log.info("link \(label): the iPad speaks wire version \(hello.version), this Mac \(CanvasWire.version)")
            sendLinkMessage(CanvasWire.bye, ByeMessage(reason: .version).json)
            closeConnection()
            phase = .versionMismatch(theirs: hello.version)
            return
        }
        peer = hello
        attempts = 0
        peerAsleep = false
        phase = .streaming(transport)
        Log.info("link \(label): streaming over \(transport.rawValue)")
        delegate?.link(self, didHello: hello)
        sendKeyframe()
    }

    private func sendLinkMessage(_ type: String, _ object: [String: Any]) {
        guard let connection, let frame = WireCodec.message(type, object) else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - Liveness (stream queue)

    private func armTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + CanvasWire.pingInterval, repeating: CanvasWire.pingInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard connection != nil else { return }
        if case .handshaking = phase, Date().timeIntervalSince(connectedAt) > CanvasWire.silenceTimeout {
            if sawLegacyFrame {
                Log.info("link \(label): the iPad speaks the old OpenDisplay-based wire — its app needs updating")
                closeConnection()
                phase = .versionMismatch(theirs: 0)
            } else {
                dropConnection("no hello from the iPad within \(Int(CanvasWire.silenceTimeout)) s")
            }
            return
        }
        if Date().timeIntervalSince(lastReceived) > CanvasWire.silenceTimeout {
            dropConnection("nothing from the iPad for \(Int(CanvasWire.silenceTimeout)) s")
            return
        }
        sendLinkMessage(CanvasWire.ping, ["t": (Date().timeIntervalSince1970 * 1000).rounded()])
    }
}
