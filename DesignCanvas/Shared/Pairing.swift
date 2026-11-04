// Who is on the other end of the link, proven (spec/wire-protocol.md,
// section 5.7). The pattern is HomeKit's and AirPlay 2's: each device has a
// long-term Ed25519 identity; pairing pins the other's public key once, and
// every connection after that proves both identities over a fresh X25519
// exchange and seals every frame with ChaCha20-Poly1305.
//
// Pairing compares a six-digit code on both screens (Bluetooth's numeric
// comparison) rather than typing one: a typed code is only safe inside a
// password-authenticated key exchange, which CryptoKit does not offer. The
// iPad commits to its nonce before it sees the Mac's, so a device in the
// middle gets one guess in a million at making the two codes match.
//
// Foundation and CryptoKit only: compiled into both apps and the tests.

import CryptoKit
import Foundation

enum PairingError: Error, Equatable {
    case badKey
    case badSignature
    case badCommitment
    case unsealFailed
    case notSealed
}

/// This device's long-term identity.
struct DeviceIdentity {
    let signingKey: Curve25519.Signing.PrivateKey

    var publicKey: Data { signingKey.publicKey.rawRepresentation }

    static func generate() -> DeviceIdentity {
        DeviceIdentity(signingKey: Curve25519.Signing.PrivateKey())
    }

    func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }
}

enum PairingCrypto {
    static let codeDigits = 6

    /// Short, stable name for a public key: what the iPad files a Mac under.
    static func fingerprint(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Everything both sides saw in the hellos, in one order. Signing it binds
    /// each long-term key to this connection's ephemeral keys.
    static func transcript(label: String, macKey: Data, macEphemeral: Data,
                           ipadKey: Data, ipadEphemeral: Data, extra: Data = Data()) -> Data {
        var data = Data("designcanvas-v2 \(label)".utf8)
        for part in [macKey, macEphemeral, ipadKey, ipadEphemeral, extra] {
            data.appendBigEndian(UInt32(part.count))
            data.append(part)
        }
        return data
    }

    static func verify(signature: Data, of data: Data, by publicKey: Data) throws {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            throw PairingError.badKey
        }
        guard key.isValidSignature(signature, for: data) else { throw PairingError.badSignature }
    }

    /// The iPad's commitment to its pairing nonce, sent before it sees the Mac's.
    static func commitment(ipadNonce: Data, transcript: Data) -> Data {
        var data = Data("designcanvas-v2 commit".utf8)
        data.append(ipadNonce)
        data.append(transcript)
        return Data(SHA256.hash(data: data))
    }

    /// The code both screens show: six digits from everything the pairing
    /// exchanged, so a key swapped by anyone in the middle changes it.
    static func code(transcript: Data, macNonce: Data, ipadNonce: Data) -> String {
        var data = Data("designcanvas-v2 code".utf8)
        data.append(transcript)
        data.append(macNonce)
        data.append(ipadNonce)
        let digest = Array(SHA256.hash(data: data))
        let value = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let digits = String(format: "%06u", value)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    /// The two directions' frame keys, from the connection's X25519 secret.
    static func sessionKeys(ownEphemeral: Curve25519.KeyAgreement.PrivateKey, peerEphemeral: Data,
                            transcript: Data) throws -> (macToIPad: SymmetricKey, ipadToMac: SymmetricKey) {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral) else {
            throw PairingError.badKey
        }
        let secret = try ownEphemeral.sharedSecretFromKeyAgreement(with: peer)
        let salt = Data(SHA256.hash(data: transcript))
        func key(_ info: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(info.utf8), outputByteCount: 32)
        }
        return (key("designcanvas-v2 mac->ipad"), key("designcanvas-v2 ipad->mac"))
    }
}

/// One direction of a sealed link: every frame after the handshake is
/// `[u32 BE length][u8 kind = 3][ChaCha20-Poly1305 of (inner kind, inner body)]`,
/// with the nonce a per-direction counter. A frame that fails to open, or
/// arrives out of order, ends the connection.
struct FrameSealer {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    /// `frame` is a whole plaintext frame from `WireCodec`; the result is the
    /// sealed frame that goes on the wire in its place.
    mutating func seal(_ frame: Data) throws -> Data {
        let inner = frame.dropFirst(4)   // kind and body
        let box = try ChaChaPoly.seal(inner, using: key, nonce: try nonce())
        counter += 1
        let sealed = box.ciphertext + box.tag
        var out = Data(capacity: 5 + sealed.count)
        out.appendBigEndian(UInt32(1 + sealed.count))
        out.append(FrameKind.sealed.rawValue)
        out.append(sealed)
        return out
    }

    private func nonce() throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        bytes.appendBigEndian(counter)
        return try ChaChaPoly.Nonce(data: bytes)
    }
}

struct FrameOpener {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    mutating func open(_ frame: RawFrame) throws -> RawFrame {
        guard frame.kind == FrameKind.sealed.rawValue else { throw PairingError.notSealed }
        guard frame.body.count >= 17 else { throw PairingError.unsealFailed }
        var nonceBytes = Data(count: 4)
        nonceBytes.appendBigEndian(counter)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: nonceBytes),
                                               ciphertext: frame.body.dropLast(16),
                                               tag: frame.body.suffix(16))
            let inner = try ChaChaPoly.open(box, using: key)
            counter += 1
            guard let kind = inner.first else { throw PairingError.unsealFailed }
            return RawFrame(kind: kind, body: Data(inner.dropFirst()))
        } catch {
            throw PairingError.unsealFailed
        }
    }
}

// MARK: - What each device remembers

/// A device this one is paired with.
struct PairedPeer: Equatable, Codable, Identifiable {
    /// Mac: the iPad's install id. iPad: the Mac's key fingerprint.
    var id: String
    var publicKey: Data
    var name: String?
    var pairedAt: Date
}

/// This device's identity and the peers it has paired with. The apps keep it
/// in the Keychain (`KeychainPairingStore`); tests keep it in memory.
protocol PairingStore: AnyObject {
    var identity: DeviceIdentity { get }
    func peer(_ id: String) -> PairedPeer?
    func pin(_ peer: PairedPeer)
    func forget(_ id: String)
    var peers: [PairedPeer] { get }
}

final class InMemoryPairingStore: PairingStore {
    let identity: DeviceIdentity
    private let lock = NSLock()
    private var stored: [String: PairedPeer] = [:]

    init(identity: DeviceIdentity = .generate()) {
        self.identity = identity
    }

    func peer(_ id: String) -> PairedPeer? { lock.withLock { stored[id] } }
    func pin(_ peer: PairedPeer) { lock.withLock { stored[peer.id] = peer } }
    func forget(_ id: String) { _ = lock.withLock { stored.removeValue(forKey: id) } }
    var peers: [PairedPeer] { lock.withLock { stored.values.sorted { $0.pairedAt < $1.pairedAt } } }
}
