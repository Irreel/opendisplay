import CryptoKit
import XCTest

/// The cryptography under pairing and every session (Pairing.swift): both
/// sides reach the same keys and code from what they exchanged, and a sealed
/// frame opens only once, in order, unaltered.
final class PairingTests: XCTestCase {

    private let mac = DeviceIdentity.generate()
    private let ipad = DeviceIdentity.generate()
    private let macEphemeral = Curve25519.KeyAgreement.PrivateKey()
    private let ipadEphemeral = Curve25519.KeyAgreement.PrivateKey()

    private func transcript(_ label: String, extra: Data = Data()) -> Data {
        PairingCrypto.transcript(label: label, macKey: mac.publicKey,
                                 macEphemeral: macEphemeral.publicKey.rawRepresentation,
                                 ipadKey: ipad.publicKey, ipadEphemeral: ipadEphemeral.publicKey.rawRepresentation,
                                 extra: extra)
    }

    func test_bothSidesDeriveTheSameSessionKeys() throws {
        let verify = transcript("verify-ipad")
        let onMac = try PairingCrypto.sessionKeys(ownEphemeral: macEphemeral,
                                                  peerEphemeral: ipadEphemeral.publicKey.rawRepresentation,
                                                  transcript: verify)
        let onIPad = try PairingCrypto.sessionKeys(ownEphemeral: ipadEphemeral,
                                                   peerEphemeral: macEphemeral.publicKey.rawRepresentation,
                                                   transcript: verify)
        let data = Data("same".utf8)
        XCTAssertEqual(HMAC<SHA256>.authenticationCode(for: data, using: onMac.macToIPad),
                       HMAC<SHA256>.authenticationCode(for: data, using: onIPad.macToIPad))
        XCTAssertEqual(HMAC<SHA256>.authenticationCode(for: data, using: onMac.ipadToMac),
                       HMAC<SHA256>.authenticationCode(for: data, using: onIPad.ipadToMac))
        XCTAssertNotEqual(HMAC<SHA256>.authenticationCode(for: data, using: onMac.macToIPad),
                          HMAC<SHA256>.authenticationCode(for: data, using: onMac.ipadToMac),
                          "each direction has its own key")
    }

    func test_aSignatureVerifiesOnlyForItsKeyAndItsTranscript() throws {
        let data = transcript("verify-mac")
        let signature = try mac.sign(data)
        XCTAssertNoThrow(try PairingCrypto.verify(signature: signature, of: data, by: mac.publicKey))
        XCTAssertThrowsError(try PairingCrypto.verify(signature: signature, of: data, by: ipad.publicKey))
        XCTAssertThrowsError(try PairingCrypto.verify(signature: signature, of: transcript("verify-ipad"), by: mac.publicKey))
    }

    /// The code depends on everything exchanged, so a key swapped in the
    /// middle shows a different code on one of the screens.
    func test_theCodeIsSixDigitsAndChangesWithAnyInput() {
        let base = transcript("pair")
        let macNonce = PairingCrypto.randomNonce(), ipadNonce = PairingCrypto.randomNonce()
        let code = PairingCrypto.code(transcript: base, macNonce: macNonce, ipadNonce: ipadNonce)
        XCTAssertNotNil(code.range(of: #"^\d{3} \d{3}$"#, options: .regularExpression))
        XCTAssertEqual(code, PairingCrypto.code(transcript: base, macNonce: macNonce, ipadNonce: ipadNonce))
        let other = PairingCrypto.transcript(label: "pair", macKey: DeviceIdentity.generate().publicKey,
                                             macEphemeral: macEphemeral.publicKey.rawRepresentation,
                                             ipadKey: ipad.publicKey,
                                             ipadEphemeral: ipadEphemeral.publicKey.rawRepresentation)
        // Different inputs give different codes with overwhelming probability;
        // two tries keep a one-in-a-million collision from flaking the test.
        let swapped = [PairingCrypto.code(transcript: other, macNonce: macNonce, ipadNonce: ipadNonce),
                       PairingCrypto.code(transcript: base, macNonce: PairingCrypto.randomNonce(), ipadNonce: ipadNonce)]
        XCTAssertTrue(swapped.contains { $0 != code })
    }

    func test_theCommitmentBindsTheNonce() {
        let base = transcript("pair")
        let nonce = PairingCrypto.randomNonce()
        let commitment = PairingCrypto.commitment(ipadNonce: nonce, transcript: base)
        XCTAssertEqual(commitment, PairingCrypto.commitment(ipadNonce: nonce, transcript: base))
        XCTAssertNotEqual(commitment, PairingCrypto.commitment(ipadNonce: PairingCrypto.randomNonce(), transcript: base))
    }

    // MARK: - Sealed frames

    private func sealedPair() -> (FrameSealer, FrameOpener) {
        let key = SymmetricKey(size: .bits256)
        return (FrameSealer(key: key), FrameOpener(key: key))
    }

    private func raw(_ frame: Data) throws -> RawFrame {
        var reader = FrameReader()
        reader.append(frame)
        return try XCTUnwrap(try reader.next())
    }

    func test_aSealedFrameOpensToTheSameFrame() throws {
        var (sealer, opener) = sealedPair()
        let plain = try XCTUnwrap(WireCodec.message("status", ["channel": "attached"], attachment: Data([0, 1, 2])))
        let sealed = try sealer.seal(plain)
        XCTAssertEqual(try raw(sealed).kind, FrameKind.sealed.rawValue)
        XCTAssertFalse(sealed.range(of: Data("attached".utf8)) != nil, "nothing readable on the wire")
        let opened = try opener.open(try raw(sealed))
        XCTAssertEqual(opened, try raw(plain))
    }

    func test_aTamperedFrameDoesNotOpen() throws {
        var (sealer, opener) = sealedPair()
        var sealed = try sealer.seal(try XCTUnwrap(WireCodec.message("ping", ["t": 1])))
        sealed[sealed.count - 20] ^= 0x01
        XCTAssertThrowsError(try opener.open(try raw(sealed)))
    }

    func test_aReplayedOrReorderedFrameDoesNotOpen() throws {
        var (sealer, opener) = sealedPair()
        let first = try sealer.seal(try XCTUnwrap(WireCodec.message("ping", ["t": 1])))
        let second = try sealer.seal(try XCTUnwrap(WireCodec.message("ping", ["t": 2])))
        XCTAssertThrowsError(try opener.open(try raw(second)), "out of order")
        var fresh = FrameOpener(key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try fresh.open(try raw(first)), "another key")
        _ = opener
    }

    func test_aPlainFrameIsRefusedOnceSealed() throws {
        var (_, opener) = sealedPair()
        XCTAssertThrowsError(try opener.open(try raw(try XCTUnwrap(WireCodec.message("ping", ["t": 1]))))) { error in
            XCTAssertEqual(error as? PairingError, .notSealed)
        }
    }

    func test_theStoreRemembersAndForgets() {
        let store = InMemoryPairingStore()
        let peer = PairedPeer(id: "ID", publicKey: ipad.publicKey, name: "iPad", pairedAt: Date())
        store.pin(peer)
        XCTAssertEqual(store.peer("ID"), peer)
        XCTAssertEqual(store.peers, [peer])
        store.forget("ID")
        XCTAssertNil(store.peer("ID"))
    }
}
