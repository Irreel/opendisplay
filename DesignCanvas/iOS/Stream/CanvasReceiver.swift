// The iPad's end of the link: listen, prove the Mac that dials (or pair with
// it, the first time), show its mirror, and carry the canvas messages both
// ways. Nothing is shown or sent before the Mac has proven itself.
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
import CryptoKit
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
        /// "USB" or "WiFi" for an accepted connection. usbmuxd delivers
        /// cable connections from loopback; tests swap this to stand in for
        /// a cable and a network on one machine.
        var transportOf: (NWConnection) -> String = CanvasReceiver.transport(of:)
        /// This iPad's identity and the Macs it is paired with.
        var pairing: PairingStore
    }

    /// A Mac this iPad is not paired with, waiting for the user to compare
    /// codes and tap Pair (both screens show `code`).
    struct PairingRequest: Equatable, Identifiable {
        let id = UUID()
        /// The Mac, as it names itself.
        let macName: String?
        let code: String
    }

    /// Another Mac asking over WiFi to take over from the one this iPad
    /// mirrors. The iPad asks its user rather than deciding: nothing on the
    /// link proves who is asking.
    struct SwitchRequest: Equatable, Identifiable {
        let id = UUID()
        /// The Mac asking, as it names itself.
        let macName: String?
        /// The Mac it would replace.
        let currentMacName: String?
        /// That Mac is on the cable, which the prompt says.
        let currentOverCable: Bool
    }

    /// What a Mac saying hello gets while another is the session.
    enum Admission: Equatable {
        case adopt
        case ask
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
    /// Up while a WiFi Mac waits for the user's answer (`answerSwitchRequest`).
    @Published private(set) var switchRequest: SwitchRequest?
    /// Up while a Mac waits for the user to confirm pairing (`answerPairing`).
    @Published private(set) var pairingRequest: PairingRequest?
    /// The Macs this iPad is paired with, for the connection screen.
    @Published private(set) var pairedMacs: [PairedPeer] = []

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
    /// When a prompt last ended without a Switch: the user kept the cable,
    /// it timed out, or the asking Mac left before the answer. Any of them
    /// starts the cooldown, so dropping the connection is no way around it.
    private var lastDeclinedAt = Date.distantPast
    /// The same for pairing: after one is cancelled, times out or is left,
    /// further WiFi pairing requests are turned away unasked for a while.
    private var lastPairingEndedAt = Date.distantPast
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
        /// Where this connection is in the handshake (section 5.7).
        var stage = Stage.awaitingHello
        /// The Mac's hello, and this side's answer to it.
        var hello: HelloMessage?
        var ownHello: HelloMessage?
        var ownEphemeral = Curve25519.KeyAgreement.PrivateKey()
        var keys: (macToIPad: SymmetricKey, ipadToMac: SymmetricKey)?
        /// Set once this side's frames are sealed, and once the Mac's are.
        var sealer: FrameSealer?
        var opener: FrameOpener?
        // Pairing.
        var ipadNonce = PairingCrypto.randomNonce()
        var macNonce: Data?
        var pairingStartedAt: Date?
        var pairingRequestID: UUID?
        var confirmedHere = false
        var confirmedThere = false
        /// A proven Mac held while the user is asked whether to switch to it,
        /// and the request the answer must name.
        var askedAt: Date?
        var requestID: UUID?

        enum Stage {
            case awaitingHello
            /// Answered with a signature; waiting for the Mac's.
            case awaitingVerify
            /// Not paired with this Mac; waiting for its `pair`.
            case awaitingPair
            case pairing
            /// Proven, and either the session or held for the user's answer.
            case proven
        }

        var macKey: Data? { hello?.key }

        init(connection: NWConnection, transport: String) {
            self.connection = connection
            self.transport = transport
        }
    }

    static func transport(of connection: NWConnection) -> String {
        let remote = String(describing: connection.endpoint)
        return remote.hasPrefix("127.0.0.1") || remote.hasPrefix("::1")
            || remote.hasPrefix("localhost") ? "USB" : "WiFi"
    }

    init(configuration: Configuration, displayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer()) {
        self.configuration = configuration
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        pairedMacs = configuration.pairing.peers
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
            guard let session = self.session, let sealed = self.outgoing(frame, for: session) else {
                deliver(false)
                return
            }
            session.connection.send(content: sealed, completion: .contentProcessed { error in
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
        let peer = Peer(connection: connection, transport: configuration.transportOf(connection))
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

    private func handle(_ raw: RawFrame, from peer: Peer) {
        var frame = raw
        if peer.opener != nil {
            // Once the Mac's side is sealed, nothing else is accepted.
            do {
                frame = try peer.opener!.open(raw)
            } catch {
                lost(peer, reason: "a frame did not open (\(error))")
                return
            }
        }
        switch FrameKind(rawValue: frame.kind) {
        case .video:
            guard peer === session, peer.opener != nil else { return }
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
        case .sealed, nil:
            if frame.kind == UInt8(ascii: "{") { peer.sawLegacyFrame = true }
        }
    }

    private func handleCandidateMessage(_ message: WireMessage, from peer: Peer) {
        switch message.type {
        case CanvasWire.ping:
            // A Mac pairing or waiting on the user is still connected and
            // pinging while the user decides.
            if peer.stage != .awaitingHello {
                sendLink(CanvasWire.pong, ["t": message.object["t"] ?? 0], to: peer)
            }
        case CanvasWire.hello:
            guard peer.stage == .awaitingHello else { return }
            handleMacHello(message.object, from: peer)
        case CanvasWire.verify:
            guard peer.stage == .awaitingVerify else { return }
            handleVerify(message.object, from: peer)
        case CanvasWire.pair:
            guard peer.stage == .awaitingVerify || peer.stage == .awaitingPair else { return }
            startPairing(peer)
        case CanvasWire.pairNonce:
            guard peer.stage == .pairing else { return }
            handleMacNonce(message.object, from: peer)
        case CanvasWire.pairConfirm:
            guard peer.stage == .pairing else { return }
            handleMacConfirm(message.object, from: peer)
        case CanvasWire.bye:
            let bye = ByeMessage(json: message.object)
            Log.info("receiver: a connecting Mac said bye (\(bye.reason.rawValue))")
            if peer.stage == .pairing {
                setStatus(bye.reason == .notPaired ? "Pairing was cancelled on your Mac" : "Pairing did not finish")
            }
            lost(peer, reason: "bye (\(bye.reason.rawValue))")
        default:
            break
        }
    }

    // MARK: - Proving the Mac, or pairing with it (queue, section 5.7)

    private func handleMacHello(_ object: [String: Any], from peer: Peer) {
        guard let hello = HelloMessage(json: object), hello.role == .mac else {
            lost(peer, reason: "the peer's hello was not a Mac's")
            return
        }
        guard hello.version == CanvasWire.version else {
            Log.info("receiver: \(hello.name ?? "a Mac") speaks wire version \(hello.version), this \(configuration.deviceKind) \(CanvasWire.version)")
            sendLink(CanvasWire.bye, ByeMessage(reason: .version).json, to: peer)
            candidates.removeAll { $0 === peer }
            let connection = peer.connection
            queue.asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
            setStatus(hello.version > CanvasWire.version
                      ? "\(hello.name ?? "Your Mac") has a newer Design Canvas — update this app"
                      : "\(hello.name ?? "Your Mac") has an older Design Canvas — update it there")
            return
        }
        guard let macKey = hello.key, let macEphemeral = hello.ephemeral else {
            lost(peer, reason: "the Mac's hello lacked its keys")
            return
        }
        let identity = configuration.pairing.identity
        let ipadEphemeral = peer.ownEphemeral.publicKey.rawRepresentation
        let verifyIPad = PairingCrypto.transcript(label: "verify-ipad", macKey: macKey, macEphemeral: macEphemeral,
                                                  ipadKey: identity.publicKey, ipadEphemeral: ipadEphemeral)
        guard let keys = try? PairingCrypto.sessionKeys(ownEphemeral: peer.ownEphemeral, peerEphemeral: macEphemeral,
                                                        transcript: verifyIPad) else {
            lost(peer, reason: "the Mac's connection key was unusable")
            return
        }
        peer.hello = hello
        peer.keys = keys
        let paired = configuration.pairing.peer(PairingCrypto.fingerprint(macKey))?.publicKey == macKey
        var mine = HelloMessage(version: CanvasWire.version, role: .ipad, name: configuration.name,
                                installID: configuration.installID, device: configuration.deviceKind,
                                key: identity.publicKey, ephemeral: ipadEphemeral)
        if paired { mine.signature = try? identity.sign(verifyIPad) }
        peer.ownHello = mine
        peer.stage = paired ? .awaitingVerify : .awaitingPair
        sendLink(CanvasWire.hello, mine.json, to: peer)
        Log.info("receiver: \(hello.name ?? "a Mac") said hello over \(peer.transport) — \(paired ? "proving it" : "not paired")")
    }

    private func transcripts(_ peer: Peer) -> (base: Data, verifyMac: Data, pairMac: Data, pairIPad: Data)? {
        guard let macKey = peer.hello?.key, let macEphemeral = peer.hello?.ephemeral,
              let ipadKey = peer.ownHello?.key, let ipadEphemeral = peer.ownHello?.ephemeral else { return nil }
        func t(_ label: String, _ extra: Data = Data()) -> Data {
            PairingCrypto.transcript(label: label, macKey: macKey, macEphemeral: macEphemeral,
                                     ipadKey: ipadKey, ipadEphemeral: ipadEphemeral, extra: extra)
        }
        let nonces = (peer.macNonce ?? Data()) + peer.ipadNonce
        return (t("pair"), t("verify-mac"), t("pair-mac", nonces), t("pair-ipad", nonces))
    }

    private func handleVerify(_ object: [String: Any], from peer: Peer) {
        guard let signature = HelloMessage.bytes(object["sig"], count: 64), let macKey = peer.macKey,
              let transcripts = transcripts(peer), let keys = peer.keys else { return }
        do {
            try PairingCrypto.verify(signature: signature, of: transcripts.verifyMac, by: macKey)
        } catch {
            Log.info("receiver: \(peer.hello?.name ?? "a Mac") did not prove the key this \(configuration.deviceKind) paired with")
            sendLink(CanvasWire.bye, ByeMessage(reason: .authFailed).json, to: peer)
            lost(peer, reason: "authentication failed")
            return
        }
        // Both directions are sealed from here.
        peer.sealer = FrameSealer(key: keys.ipadToMac)
        peer.opener = FrameOpener(key: keys.macToIPad)
        peer.stage = .proven
        admit(peer, justPaired: false)
    }

    /// The Mac does not have this iPad (or this iPad not the Mac): pair. The
    /// iPad commits to its nonce first.
    private func startPairing(_ peer: Peer) {
        guard let transcripts = transcripts(peer) else { return }
        peer.stage = .pairing
        peer.pairingStartedAt = Date()
        let commitment = PairingCrypto.commitment(ipadNonce: peer.ipadNonce, transcript: transcripts.base)
        sendLink(CanvasWire.pairCommit, ["c": commitment.base64EncodedString()], to: peer)
        setStatus("Pairing with \(peer.hello?.name ?? "your Mac")…")
    }

    private func handleMacNonce(_ object: [String: Any], from peer: Peer) {
        guard peer.macNonce == nil, let macNonce = HelloMessage.bytes(object["n"], count: 32) else { return }
        peer.macNonce = macNonce
        sendLink(CanvasWire.pairNonce, ["n": peer.ipadNonce.base64EncodedString()], to: peer)
        guard let transcripts = transcripts(peer) else { return }
        let code = PairingCrypto.code(transcript: transcripts.base, macNonce: macNonce, ipadNonce: peer.ipadNonce)
        guard !candidates.contains(where: { $0 !== peer && $0.pairingRequestID != nil }) else {
            Log.info("receiver: another pairing is already waiting on the user — turned away")
            sendLink(CanvasWire.bye, ByeMessage(reason: .notPaired).json, to: peer)
            lost(peer, reason: "another pairing is open")
            return
        }
        guard peer.transport == "USB" || Date().timeIntervalSince(lastPairingEndedAt) > CanvasWire.switchRequestCooldown else {
            Log.info("receiver: a pairing request over WiFi within a minute of the last one ending — turned away unasked")
            sendLink(CanvasWire.bye, ByeMessage(reason: .notPaired).json, to: peer)
            lost(peer, reason: "pairing cooldown")
            return
        }
        let request = PairingRequest(macName: peer.hello?.name, code: code)
        peer.pairingRequestID = request.id
        DispatchQueue.main.async { self.pairingRequest = request }
    }

    /// The user's answer to the pairing request with this `id`: Pair once the
    /// codes match, or Cancel. An answer to a request that is gone does nothing.
    func answerPairing(id: UUID, accept: Bool) {
        queue.async {
            guard let peer = self.candidates.first(where: { $0.pairingRequestID == id }),
                  !peer.confirmedHere else { return }
            guard accept else {
                Log.info("receiver: the user cancelled pairing")
                self.clearPairingRequest(id: id)
                self.sendLink(CanvasWire.bye, ByeMessage(reason: .notPaired).json, to: peer)
                self.setStatus("Pairing cancelled")
                self.lost(peer, reason: "pairing cancelled")
                return
            }
            guard let transcripts = self.transcripts(peer), let keys = peer.keys,
                  let signature = try? self.configuration.pairing.identity.sign(transcripts.pairIPad) else { return }
            self.clearPairingRequest(id: id)
            self.sendLink(CanvasWire.pairConfirm, ["sig": signature.base64EncodedString()], to: peer)
            // This side's frames are sealed from here on.
            peer.sealer = FrameSealer(key: keys.ipadToMac)
            peer.confirmedHere = true
            if !peer.confirmedThere { self.setStatus("Confirm the code on your Mac") }
            self.finishPairingIfDone(peer)
        }
    }

    private func handleMacConfirm(_ object: [String: Any], from peer: Peer) {
        guard !peer.confirmedThere, peer.macNonce != nil, let signature = HelloMessage.bytes(object["sig"], count: 64),
              let macKey = peer.macKey, let transcripts = transcripts(peer), let keys = peer.keys else { return }
        do {
            try PairingCrypto.verify(signature: signature, of: transcripts.pairMac, by: macKey)
        } catch {
            Log.info("receiver: the Mac's pairing confirmation did not verify")
            lost(peer, reason: "pairing failed")
            return
        }
        // The Mac's frames are sealed from here on.
        peer.opener = FrameOpener(key: keys.macToIPad)
        peer.confirmedThere = true
        finishPairingIfDone(peer)
    }

    private func finishPairingIfDone(_ peer: Peer) {
        guard peer.confirmedHere, peer.confirmedThere, let macKey = peer.macKey else { return }
        let fingerprint = PairingCrypto.fingerprint(macKey)
        configuration.pairing.pin(PairedPeer(id: fingerprint, publicKey: macKey, name: peer.hello?.name, pairedAt: Date()))
        publishPairedMacs()
        peer.pairingRequestID = nil
        peer.stage = .proven
        Log.info("receiver: paired with \(peer.hello?.name ?? "a Mac")")
        // The user just chose this Mac on this iPad: no further question.
        admit(peer, justPaired: true)
    }

    private func clearPairingRequest(id: UUID?) {
        DispatchQueue.main.async {
            guard let shown = self.pairingRequest, id == nil || shown.id == id else { return }
            self.pairingRequest = nil
        }
    }

    /// The Macs this iPad is paired with, for the connection screen.
    func forgetMac(id: String) {
        queue.async {
            self.configuration.pairing.forget(id)
            self.publishPairedMacs()
            if let session = self.session, let key = session.macKey, PairingCrypto.fingerprint(key) == id {
                self.sendLink(CanvasWire.bye, ByeMessage(reason: .notPaired).json, to: session)
                self.endSession(session)
                self.setStatus("Waiting for your Mac")
            }
            Log.info("receiver: forgot a Mac")
        }
    }

    private func publishPairedMacs() {
        let peers = configuration.pairing.peers
        DispatchQueue.main.async { self.pairedMacs = peers }
    }

    // MARK: - Admission (queue)

    /// A proven Mac: take it as the session, or ask the user first.
    private func admit(_ peer: Peer, justPaired: Bool) {
        guard let current = session, !justPaired,
              Self.admission(currentTransport: current.transport, currentMacKey: current.macKey,
                             newcomerTransport: peer.transport, newcomerMacKey: peer.macKey) == .ask else {
            adopt(peer)
            return
        }
        // One question at a time: a second Mac asking meanwhile is told the
        // iPad is in use. So is one asking soon after the user said no, so the
        // question cannot be repeated until someone taps Switch to stop it.
        guard !candidates.contains(where: { $0 !== peer && $0.requestID != nil }) else {
            Log.info("receiver: \(peer.hello?.name ?? "a Mac") asked while another request is open — turned away")
            refuse(peer)
            return
        }
        guard Date().timeIntervalSince(lastDeclinedAt) > CanvasWire.switchRequestCooldown else {
            Log.info("receiver: \(peer.hello?.name ?? "a Mac") asked within a minute of the last no — turned away unasked")
            refuse(peer)
            return
        }
        Log.info("receiver: \(peer.hello?.name ?? "a Mac") asked over WiFi while \(current.transport == "USB" ? "a cabled" : "another") Mac is connected — asking the user")
        let request = SwitchRequest(macName: peer.hello?.name, currentMacName: current.hello?.name,
                                    currentOverCable: current.transport == "USB")
        peer.askedAt = Date()
        peer.requestID = request.id
        sendLink(CanvasWire.asking, [:], to: peer)
        DispatchQueue.main.async { self.switchRequest = request }
    }

    /// The user's answer to the request with this `id`. Switching adopts the
    /// asking Mac, which tells the current one it was replaced; keeping the
    /// current one tells the asking Mac the iPad is in use. An answer to a
    /// request that is no longer the open one (it timed out, its Mac left,
    /// another took its place) does nothing: a Switch is only ever for the
    /// Mac it was asked about.
    func answerSwitchRequest(id: UUID, switchTo: Bool) {
        queue.async {
            guard let peer = self.candidates.first(where: { $0.requestID == id }) else {
                Log.info("receiver: an answer arrived for a switch request that is no longer open — ignored")
                return
            }
            self.clearSwitchRequest(id: id)
            if switchTo {
                Log.info("receiver: the user switched to \(peer.hello?.name ?? "the Mac")")
                peer.askedAt = nil
                peer.requestID = nil
                self.adopt(peer)
            } else {
                Log.info("receiver: the user kept the current Mac")
                self.lastDeclinedAt = Date()
                self.refuse(peer)
            }
        }
    }

    private func refuse(_ peer: Peer) {
        sendLink(CanvasWire.bye, ByeMessage(reason: .inUse).json, to: peer)
        candidates.removeAll { $0 === peer }
        let connection = peer.connection
        queue.asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
    }

    /// Takes the alert down: any request, or only the one with `id`, so a
    /// late clear never takes down a newer question.
    private func clearSwitchRequest(id: UUID? = nil) {
        DispatchQueue.main.async {
            guard let shown = self.switchRequest, id == nil || shown.id == id else { return }
            self.switchRequest = nil
        }
    }

    /// Whether a proven newcomer takes the session at once or the user is
    /// asked. A cable is physical intent, so plugging one in takes over; the
    /// Mac already being mirrored, back on a new connection, is recognised by
    /// the key it proved and let straight in; another Mac over WiFi waits for
    /// the user, whatever the session runs on.
    static func admission(currentTransport: String, currentMacKey: Data?,
                          newcomerTransport: String, newcomerMacKey: Data?) -> Admission {
        if newcomerTransport == "USB" { return .adopt }
        if let newcomerMacKey, newcomerMacKey == currentMacKey { return .adopt }
        return .ask
    }

    /// Make `peer` the session, replacing any other.
    private func adopt(_ peer: Peer) {
        candidates.removeAll { $0 === peer }
        if let previous = session {
            Log.info("receiver: a newer connection replaces the session")
            sendLink(CanvasWire.bye, ByeMessage(reason: .replaced).json, to: previous)
            let connection = previous.connection
            queue.asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
        }
        session = peer
        resetStream()
        sendLink(CanvasWire.ready, [:], to: peer)
        guard let hello = peer.hello else { return }
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
        case CanvasWire.hello, CanvasWire.verify, CanvasWire.pair, CanvasWire.pairNonce, CanvasWire.pairConfirm:
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
            // Not at once: a bye just sent to it would be dropped. Untracked,
            // nothing it sends meanwhile is read.
            let connection = peer.connection
            queue.asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
            if let id = peer.requestID {
                Log.info("receiver: the Mac asking to switch went away (\(reason))")
                clearSwitchRequest(id: id)
                lastDeclinedAt = Date()
            }
            if let id = peer.pairingRequestID {
                // Cancelled, timed out, or the Mac left: the cooldown starts.
                clearPairingRequest(id: id)
                lastPairingEndedAt = Date()
            }
            if peer.sawLegacyFrame {
                setStatus("A Mac with an older Design Canvas tried to connect — update it there")
            }
        }
    }

    private func endSession(_ peer: Peer) {
        guard peer === session else { return }
        session = nil
        // As in `lost`: a bye just sent must get out first.
        let connection = peer.connection
        queue.asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
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
                self.candidates.forEach { $0.connection.cancel() }
                self.candidates.removeAll()
                self.clearSwitchRequest()
                self.clearPairingRequest(id: nil)
                self.listener?.cancel()
                self.listener = nil
                self.listenerHealthy = false
                self.setStatus(text)
                completion?()
            }
            guard let session = self.session,
                  let frame = self.outgoing(WireCodec.message(CanvasWire.bye, ByeMessage(reason: reason).json), for: session) else {
                finish()
                return
            }
            Log.info("receiver: closing — telling the Mac (\(reason.rawValue))")
            session.connection.send(content: frame, completion: .contentProcessed { _ in
                self.queue.async { finish() }
            })
            // The send may never complete on a dying link.
            self.queue.asyncAfter(deadline: .now() + 1) { finish() }
        }
    }

    /// A frame as it goes to `peer`: sealed once this side has switched, in
    /// send order, so the counter matches the Mac's.
    private func outgoing(_ frame: Data?, for peer: Peer) -> Data? {
        guard let frame else { return nil }
        guard peer.sealer != nil else { return frame }
        return try? peer.sealer!.seal(frame)
    }

    private func sendLink(_ type: String, _ object: [String: Any], to peer: Peer) {
        guard let frame = outgoing(WireCodec.message(type, object), for: peer) else { return }
        peer.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// To the session, when there is one.
    private func sendLinkMessage(_ type: String, _ object: [String: Any]) {
        guard let session else { return }
        sendLink(type, object, to: session)
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
        for candidate in candidates {
            if let askedAt = candidate.askedAt {
                if now.timeIntervalSince(askedAt) > CanvasWire.switchRequestTimeout {
                    Log.info("receiver: no answer to the switch request — keeping the current Mac")
                    clearSwitchRequest(id: candidate.requestID)
                    lastDeclinedAt = now
                    refuse(candidate)
                } else if now.timeIntervalSince(candidate.lastReceived) > CanvasWire.silenceTimeout {
                    lost(candidate, reason: "silent while waiting")
                }
            } else if let started = candidate.pairingStartedAt {
                if now.timeIntervalSince(started) > CanvasWire.pairingTimeout {
                    Log.info("receiver: pairing timed out")
                    sendLink(CanvasWire.bye, ByeMessage(reason: .notPaired).json, to: candidate)
                    setStatus("Pairing timed out")
                    lost(candidate, reason: "pairing timed out")
                } else if now.timeIntervalSince(candidate.lastReceived) > CanvasWire.silenceTimeout {
                    lost(candidate, reason: "silent while pairing")
                }
            } else if now.timeIntervalSince(candidate.acceptedAt) > CanvasWire.silenceTimeout {
                lost(candidate, reason: "no hello")
            }
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
