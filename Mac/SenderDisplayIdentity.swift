// What a sender calls the virtual displays it creates.
//
// macOS keys saved display state — arrangement, mode, and the hostile state
// that keeps an identity from ever coming online again (#206, #221) — on the
// display's vendor/product/serial. The serial is derived from the session id,
// which for a cabled device is `usb:<udid>`: two products that share a
// productID therefore share that state for the same iPad, while each persists
// the offset that escapes a poisoned identity in its OWN defaults. A second
// product built on this sender must bring its own productID, or it inherits
// every identity the first one abandoned without knowing to skip them.
//
// Foundation only, like `SenderDiscoveryConfig`, so it compiles into the
// hostless test bundles.

import Foundation

struct SenderDisplayIdentity: Equatable {
    /// productID of a device's base identity. It moves with the serial when an
    /// identity is abandoned — see `MacSender.setupExtend`. The default is
    /// OpenDisplay's shipped value ("OS"); changing it orphans saved state.
    var productIDBase: UInt32 = 0x4F53
    /// The brand in the display's name, as System Settings shows it.
    var namePrefix = "OpenDisplay"

    /// The productID for the identity `offset` steps from the base one.
    func productID(offset: UInt32) -> UInt32 { productIDBase &+ offset }

    /// USB sessions can start before lockdown resolves the device name — fall
    /// back to the kind from the hello rather than the generic label.
    func displayName(endpointName: String, kind: String) -> String {
        endpointName.hasPrefix("iPhone / iPad")
            ? "\(namePrefix) — \(kind)"
            : "\(namePrefix) — \(endpointName)"
    }
}
