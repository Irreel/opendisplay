// One iPad, from the Mac's side: dial it, prove who each side is (or pair
// them, the first time), stream the mirror to it, carry its canvas messages,
// and dial again whenever the connection goes.
//
// A link lives as long as the Mac means to serve that iPad, across any number
// of connections. Moving between USB and WiFi is just another reconnect: the
// iPad adopts whichever connection proves itself last, and there is no virtual
// display or window arrangement on the Mac that a reconnect could disturb.
//
// Everything here runs on the stream queue the engine hands in; the public
// methods hop onto it.

import CryptoKit
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
    /// to hold it to (the user clicked a service that advertised no id).
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
    /// Connected; saying hello and proving identities.
    case handshaking(LinkTransport)
    /// The first time with this iPad: both screens show `code`, and both
    /// users have to confirm it (nil until the code is known).
    case pairing(LinkTransport, code: String?)
    /// The iPad is mirroring another Mac and is asking its user whether to
    /// switch to this one.
    case awaitingApproval(LinkTransport)
    case streaming(LinkTransport)
    /// Between attempts, with why the last one ended.
    case retrying(RetryReason)
    /// Another Mac took this iPad over. No redial until something changes.
    case yielded
    /// Pairing was declined, cancelled or timed out. No redial until the user
    /// connects again or the iPad reappears.
    case notPaired
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
    /// The iPad proved its identity and made this connection its session:
    /// streaming starts now.
    func link(_ link: MirrorLink, didHello peer: HelloMessage)
    /// Pairing reached its code: show it, and answer with `answerPairing`.
    func link(_ link: MirrorLink, confirmPairing code: String, with peer: HelloMessage)
    /// Pairing finished on both sides: the iPad is pinned in the store.
    func link(_ link: MirrorLink, didPair peer: HelloMessage)
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
    private let macName: String?
    private let pairing: PairingStore
    private let frames: CleanFrameStore
    private let quality: StreamQuality
    private let port: UInt16

    // All below: stream queue only.
    private var paths = LinkPaths.none
    private(set) var phase: LinkPhase = .idle {
        didSet { if phase != oldValue { delegate?.link(self, didChangePhase: phase) } }
    }
    /// The iPad's hello on the connection that last proved itself.
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

    // The handshake of the current connection (section 5.7).
    private var ownEphemeral = Curve25519.KeyAgreement.PrivateKey()
    private var ownHello: HelloMessage?
    private var peerHello: HelloMessage?
    private var keys: (macToIPad: SymmetricKey, ipadToMac: SymmetricKey)?
    /// Set once this side's frames are sealed, and once the iPad's are.
    private var sealer: FrameSealer?
    private var opener: FrameOpener?
    private var pairingState: PairingState?
    /// The user asked for this iPad (a Connect click) since the last pairing
    /// ended. Pairing starts only from that or a cable: a WiFi reconnect that
    /// fails its proof is an impostor as likely as a reinstalled iPad, and must
    /// not put a pairing question in front of the user unasked.
    private var pairingAllowedByUser = false

    private struct PairingState {
        let macNonce = PairingCrypto.randomNonce()
        var commitment: Data?
        var ipadNonce: Data?
        var code: String?
        var confirmedHere = false
        var confirmedThere = false
    }

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

    init(id: String = UUID().uuidString, queue: DispatchQueue, macName: String?, pairing: PairingStore,
         frames: CleanFrameStore, quality: StreamQuality = .stored, port: UInt16 = CanvasWire.port) {
        self.id = id
        self.queue = queue
        self.macName = macName
        self.pairing = pairing
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
            case .idle, .retrying, .yielded, .notPaired:
                self.attempts = 0
                self.dialIfPossible()
            case .streaming(.wifi), .handshaking(.wifi), .awaitingApproval(.wifi), .dialing(.wifi):
                // Not mid-pairing: that waits on users who can both see it.
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

    /// Dial again now, whatever the link was doing (the user asked), and
    /// pair if the iPad needs it.
    func reconnect() {
        queue.async {
            guard self.started, self.phase != .stopped else { return }
            self.pairingAllowedByUser = true
            self.reconnectNow()
        }
    }

    /// The user clicked Connect for this iPad: pairing it, if needed, is wanted.
    func allowPairing() {
        queue.async { self.pairingAllowedByUser = true }
    }

    /// The user's answer to `confirmPairing`.
    func answerPairing(accept: Bool) {
        queue.async {
            guard case .pairing = self.phase, var state = self.pairingState, state.code != nil,
                  !state.confirmedHere else { return }
            guard accept else {
                Log.info("link \(self.label): pairing declined on this Mac")
                self.sayBye(.notPaired)
                self.endPairing("declined on this Mac")
                return
            }
            guard let transcripts = self.pairingTranscripts(state),
                  let signature = try? self.pairing.identity.sign(transcripts.mac),
                  let keys = self.keys else { return }
            self.sendLink(CanvasWire.pairConfirm, ["sig": signature.base64EncodedString()])
            // This side's frames are sealed from here on.
            self.sealer = FrameSealer(key: keys.macToIPad)
            state.confirmedHere = true
            self.pairingState = state
            self.finishPairingIfDone()
        }
    }

    /// End the link for good. With `bye`, the iPad is told so it does not
    /// read the silence as a fault.
    func stop(bye: ByeMessage.Reason? = nil) {
        queue.async {
            guard self.phase != .stopped else { return }
            if let bye, let connection = self.connection,
               let frame = self.outgoing(WireCodec.message(CanvasWire.bye, ByeMessage(reason: bye).json)) {
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
    /// the send itself happens on the queue and only on a link that is
    /// streaming. A message that finds the link down is dropped with a log
    /// line: the next session resends everything a reconnecting iPad needs.
    @discardableResult
    func send(_ type: String, _ object: [String: Any], attachment: Data) -> Bool {
        guard let frame = WireCodec.message(type, object, attachment: attachment) else {
            Log.info("link: refused to send \(type) — not serialisable, or over the size limit")
            return false
        }
        queue.async {
            guard case .streaming = self.phase, let connection = self.connection,
                  let sealed = self.outgoing(frame) else {
                Log.info("link \(self.label): \(type) dropped — not connected")
                return
            }
            connection.send(content: sealed, completion: .contentProcessed { _ in })
        }
        return true
    }

    /// A frame as it goes on the wire: sealed once this side has switched,
    /// in send order, so the counter matches the iPad's. Nil when sealing
    /// failed, which ends the connection.
    private func outgoing(_ frame: Data?) -> Data? {
        guard let frame else { return nil }
        guard sealer != nil else { return frame }
        do {
            return try sealer!.seal(frame)
        } catch {
            dropConnection("could not seal a frame (\(error))")
            return nil
        }
    }

    private func sendLink(_ type: String, _ object: [String: Any]) {
        guard let connection, let frame = outgoing(WireCodec.message(type, object)) else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// Says bye, and lets the connection go only once the bye is out: a
    /// cancel straight after a send can drop it. `closeConnection` then has
    /// no connection left to cancel.
    private func sayBye(_ reason: ByeMessage.Reason) {
        guard let connection, let frame = outgoing(WireCodec.message(CanvasWire.bye, ByeMessage(reason: reason).json)) else { return }
        connection.stateUpdateHandler = nil
        connection.send(content: frame, completion: .contentProcessed { _ in connection.cancel() })
        self.connection = nil
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
            guard let frame = outgoing(WireCodec.video(packet)) else { return }
            videoInFlight += 1
            connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
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

    private var label: String { peer?.name ?? peerHello?.name ?? id.prefix(8).description }

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
            if case .failed(let error) = state {
                self.dropConnection("connection failed: \(error)")
            }
        }
        // A fresh ephemeral key per connection: what one connection's keys
        // would reveal says nothing about any other.
        ownEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = HelloMessage(version: CanvasWire.version, role: .mac, name: macName,
                                 key: pairing.identity.publicKey,
                                 ephemeral: ownEphemeral.publicKey.rawRepresentation)
        ownHello = hello
        sendLink(CanvasWire.hello, hello.json)
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
        ownHello = nil
        peerHello = nil
        keys = nil
        sealer = nil
        opener = nil
        pairingState = nil
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

    private func handle(_ raw: RawFrame) {
        var frame = raw
        if opener != nil {
            // Once the iPad's side is sealed, nothing else is accepted.
            do {
                frame = try opener!.open(raw)
            } catch {
                dropConnection("a frame did not open (\(error))")
                return
            }
        }
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
        case CanvasWire.pairCommit:
            handlePairCommit(message.object)
        case CanvasWire.pairNonce:
            handlePairNonce(message.object)
        case CanvasWire.pairConfirm:
            handlePairConfirm(message.object)
        case CanvasWire.ready:
            handleReady()
        case CanvasWire.ping:
            sendLink(CanvasWire.pong, ["t": message.object["t"] ?? 0])
        case CanvasWire.pong:
            break
        case CanvasWire.keyframe:
            sendKeyframe()
        case CanvasWire.asking:
            guard case .handshaking(let transport) = phase, opener != nil else { return }
            Log.info("link \(label): the iPad is asking its user whether to switch to this Mac")
            connectedAt = Date()
            phase = .awaitingApproval(transport)
        case CanvasWire.bye:
            handleBye(ByeMessage(json: message.object))
        default:
            guard case .streaming = phase else { return }
            delegate?.link(self, didReceive: message)
        }
    }

    private func handleBye(_ bye: ByeMessage) {
        Log.info("link \(label): the iPad said bye (\(bye.reason.rawValue))")
        let wasStreaming: Bool
        if case .streaming = phase { wasStreaming = true } else { wasStreaming = false }
        closeConnection()
        if wasStreaming { delegate?.linkDidDrop(self) }
        switch bye.reason {
        case .replaced, .inUse:
            phase = .yielded
        case .version:
            phase = .versionMismatch(theirs: 0)
        case .notPaired:
            phase = .notPaired
        case .authFailed:
            // This Mac's proof did not match what the iPad pinned. Not
            // something a redial fixes; the user can connect (and pair) again.
            phase = .notPaired
        case .sleep, .quit:
            attempts = 0
            peerAsleep = bye.reason == .sleep
            scheduleRetry(bye.reason == .sleep ? .asleep : .appNotOpen)
        }
    }

    // MARK: - Proving identities (stream queue, section 5.7)

    private func handleHello(_ object: [String: Any]) {
        guard case .handshaking(let transport) = phase, peerHello == nil, let ownHello else { return }
        guard let hello = HelloMessage(json: object), hello.role == .ipad else {
            dropConnection("the peer's hello was not an iPad's")
            return
        }
        guard hello.version == CanvasWire.version else {
            Log.info("link \(label): the iPad speaks wire version \(hello.version), this Mac \(CanvasWire.version)")
            sayBye(.version)
            closeConnection()
            phase = .versionMismatch(theirs: hello.version)
            return
        }
        if transport == .wifi, let expected = paths.wifiInstallID, hello.installID != expected {
            Log.info("link \(label): the hello over WiFi names another iPad than the service advertised")
            dropConnection("identity mismatch")
            return
        }
        guard let installID = hello.installID, let ipadKey = hello.key, let ipadEphemeral = hello.ephemeral,
              let macKey = ownHello.key, let macEphemeral = ownHello.ephemeral else {
            dropConnection("the iPad's hello lacked its keys")
            return
        }
        peerHello = hello
        let verifyIPad = PairingCrypto.transcript(label: "verify-ipad", macKey: macKey, macEphemeral: macEphemeral,
                                                  ipadKey: ipadKey, ipadEphemeral: ipadEphemeral)
        guard let derived = try? PairingCrypto.sessionKeys(ownEphemeral: ownEphemeral, peerEphemeral: ipadEphemeral,
                                                           transcript: verifyIPad) else {
            dropConnection("the iPad's connection key was unusable")
            return
        }
        keys = derived

        // Paired, and the iPad proved it holds the key this Mac pinned.
        if let pinned = pairing.peer(installID), pinned.publicKey == ipadKey, let signature = hello.signature {
            do {
                try PairingCrypto.verify(signature: signature, of: verifyIPad, by: pinned.publicKey)
            } catch {
                Log.info("link \(label): the iPad's signature did not match the key this Mac paired with")
                sayBye(.authFailed)
                closeConnection()
                phase = .notPaired
                return
            }
            let verifyMac = PairingCrypto.transcript(label: "verify-mac", macKey: macKey, macEphemeral: macEphemeral,
                                                     ipadKey: ipadKey, ipadEphemeral: ipadEphemeral)
            guard let signature = try? pairing.identity.sign(verifyMac) else { return }
            sendLink(CanvasWire.verify, ["sig": signature.base64EncodedString()])
            // Both directions are sealed from here: the iPad sends nothing
            // between its hello and this verify.
            sealer = FrameSealer(key: derived.macToIPad)
            opener = FrameOpener(key: derived.ipadToMac)
            Log.info("link \(label): the iPad proved itself — waiting for it to take the session")
            return
        }

        // Not paired with this iPad (or its key changed, a reinstall): pair,
        // but only over the cable or when the user asked for it.
        guard transport == .usb || pairingAllowedByUser else {
            Log.info("link \(label): the iPad did not prove a paired key, and nobody asked to pair — not pairing")
            sayBye(.notPaired)
            closeConnection()
            phase = .notPaired
            return
        }
        if pairing.peer(installID) != nil {
            Log.info("link \(label): the iPad's key is not the one this Mac paired with — pairing again")
        }
        pairingState = PairingState()
        phase = .pairing(transport, code: nil)
        sendLink(CanvasWire.pair, [:])
        Log.info("link \(label): not paired — pairing")
    }

    /// The two signed pairing transcripts, once both nonces are known.
    private func pairingTranscripts(_ state: PairingState) -> (mac: Data, ipad: Data)? {
        guard let ownHello, let peerHello, let macKey = ownHello.key, let macEphemeral = ownHello.ephemeral,
              let ipadKey = peerHello.key, let ipadEphemeral = peerHello.ephemeral,
              let ipadNonce = state.ipadNonce else { return nil }
        let nonces = state.macNonce + ipadNonce
        return (PairingCrypto.transcript(label: "pair-mac", macKey: macKey, macEphemeral: macEphemeral,
                                         ipadKey: ipadKey, ipadEphemeral: ipadEphemeral, extra: nonces),
                PairingCrypto.transcript(label: "pair-ipad", macKey: macKey, macEphemeral: macEphemeral,
                                         ipadKey: ipadKey, ipadEphemeral: ipadEphemeral, extra: nonces))
    }

    private var baseTranscript: Data? {
        guard let ownHello, let peerHello, let macKey = ownHello.key, let macEphemeral = ownHello.ephemeral,
              let ipadKey = peerHello.key, let ipadEphemeral = peerHello.ephemeral else { return nil }
        return PairingCrypto.transcript(label: "pair", macKey: macKey, macEphemeral: macEphemeral,
                                        ipadKey: ipadKey, ipadEphemeral: ipadEphemeral)
    }

    /// The iPad commits to its nonce before it may see this Mac's.
    private func handlePairCommit(_ object: [String: Any]) {
        guard case .pairing = phase, var state = pairingState, state.commitment == nil,
              let commitment = HelloMessage.bytes(object["c"], count: 32) else { return }
        state.commitment = commitment
        pairingState = state
        sendLink(CanvasWire.pairNonce, ["n": state.macNonce.base64EncodedString()])
    }

    private func handlePairNonce(_ object: [String: Any]) {
        guard case .pairing(let transport, _) = phase, var state = pairingState, let commitment = state.commitment,
              state.ipadNonce == nil, let ipadNonce = HelloMessage.bytes(object["n"], count: 32),
              let base = baseTranscript else { return }
        guard PairingCrypto.commitment(ipadNonce: ipadNonce, transcript: base) == commitment else {
            Log.info("link \(label): the iPad's pairing nonce did not match its commitment")
            sayBye(.notPaired)
            endPairing("bad commitment")
            return
        }
        state.ipadNonce = ipadNonce
        let code = PairingCrypto.code(transcript: base, macNonce: state.macNonce, ipadNonce: ipadNonce)
        state.code = code
        pairingState = state
        phase = .pairing(transport, code: code)
        if let peerHello { delegate?.link(self, confirmPairing: code, with: peerHello) }
    }

    private func handlePairConfirm(_ object: [String: Any]) {
        guard case .pairing = phase, var state = pairingState, state.code != nil, !state.confirmedThere,
              let signature = HelloMessage.bytes(object["sig"], count: 64),
              let transcripts = pairingTranscripts(state), let ipadKey = peerHello?.key, let keys else { return }
        do {
            try PairingCrypto.verify(signature: signature, of: transcripts.ipad, by: ipadKey)
        } catch {
            Log.info("link \(label): the iPad's pairing confirmation did not verify")
            dropConnection("pairing failed")
            return
        }
        // The iPad's frames are sealed from here on.
        opener = FrameOpener(key: keys.ipadToMac)
        state.confirmedThere = true
        pairingState = state
        finishPairingIfDone()
    }

    private func finishPairingIfDone() {
        guard case .pairing(let transport, _) = phase, let state = pairingState, state.confirmedHere,
              state.confirmedThere, let peerHello, let installID = peerHello.installID,
              let ipadKey = peerHello.key else { return }
        pairing.pin(PairedPeer(id: installID, publicKey: ipadKey, name: peerHello.name, pairedAt: Date()))
        pairingState = nil
        pairingAllowedByUser = false
        // The iPad's `ready` follows at once; the handshake clock restarts.
        connectedAt = Date()
        phase = .handshaking(transport)
        Log.info("link \(label): paired")
        delegate?.link(self, didPair: peerHello)
    }

    private func endPairing(_ reason: String) {
        Log.info("link \(label): pairing ended (\(reason))")
        pairingAllowedByUser = false
        closeConnection()
        phase = .notPaired
    }

    /// The iPad made this connection its session.
    private func handleReady() {
        let transport: LinkTransport
        switch phase {
        case .handshaking(let current), .awaitingApproval(let current): transport = current
        default: return
        }
        guard opener != nil, sealer != nil, let peerHello else { return }
        peer = peerHello
        attempts = 0
        peerAsleep = false
        phase = .streaming(transport)
        Log.info("link \(label): streaming over \(transport.rawValue)")
        delegate?.link(self, didHello: peerHello)
        sendKeyframe()
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
        let age = Date().timeIntervalSince(connectedAt)
        switch phase {
        case .pairing:
            if age > CanvasWire.pairingTimeout {
                sayBye(.notPaired)
                endPairing("timed out")
                return
            }
        case .awaitingApproval:
            if age > CanvasWire.switchRequestMacWait {
                dropConnection("no answer on the iPad")
                return
            }
        case .handshaking:
            if age > CanvasWire.silenceTimeout {
                if sawLegacyFrame {
                    Log.info("link \(label): the iPad speaks the old OpenDisplay-based wire — its app needs updating")
                    closeConnection()
                    phase = .versionMismatch(theirs: 0)
                } else {
                    dropConnection("the iPad did not finish its hello within \(Int(CanvasWire.silenceTimeout)) s")
                }
                return
            }
        default:
            break
        }
        if Date().timeIntervalSince(lastReceived) > CanvasWire.silenceTimeout {
            dropConnection("nothing from the iPad for \(Int(CanvasWire.silenceTimeout)) s")
            return
        }
        sendLink(CanvasWire.ping, ["t": (Date().timeIntervalSince1970 * 1000).rounded()])
    }
}
