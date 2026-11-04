// The apps' `PairingStore`: this device's private identity key and its list
// of paired peers, in the Keychain, readable only by this app and only on
// this device. The peers are public keys, but kept beside the private one so
// that what this device trusts cannot be edited as a plain preference.

import CryptoKit
import Foundation
import Security

final class KeychainPairingStore: PairingStore {
    private let service: String
    private let lock = NSLock()
    private var cachedPeers: [String: PairedPeer]
    let identity: DeviceIdentity

    private static let identityAccount = "identity"
    private static let peersAccount = "peers"

    init(service: String = "com.designcanvas.pairing") {
        self.service = service
        if let raw = Self.read(service: service, account: Self.identityAccount),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            identity = DeviceIdentity(signingKey: key)
        } else {
            identity = .generate()
            Self.write(identity.signingKey.rawRepresentation, service: service, account: Self.identityAccount)
            Log.info("pairing: created this device's identity")
        }
        let peers = Self.read(service: service, account: Self.peersAccount)
            .flatMap { try? JSONDecoder().decode([PairedPeer].self, from: $0) } ?? []
        cachedPeers = Dictionary(peers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    func peer(_ id: String) -> PairedPeer? { lock.withLock { cachedPeers[id] } }

    func pin(_ peer: PairedPeer) {
        lock.withLock {
            cachedPeers[peer.id] = peer
            save()
        }
    }

    func forget(_ id: String) {
        lock.withLock {
            cachedPeers.removeValue(forKey: id)
            save()
        }
    }

    var peers: [PairedPeer] { lock.withLock { cachedPeers.values.sorted { $0.pairedAt < $1.pairedAt } } }

    /// Under `lock`.
    private func save() {
        guard let data = try? JSONEncoder().encode(Array(cachedPeers.values)) else { return }
        Self.write(data, service: service, account: Self.peersAccount)
    }

    private static func read(service: String, account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, service: String, account: String) {
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Log.info("pairing: the Keychain refused to save (\(status))")
        }
    }
}
