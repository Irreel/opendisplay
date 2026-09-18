// Design Canvas's own virtual-display identity.
//
// The same iPad on the same cable gets the same display serial from both
// products, so without its own productID a Design Canvas display IS an
// OpenDisplay display as far as macOS's saved display state is concerned. That
// is how the first hardware session failed: macOS held hostile state for the
// three identities OpenDisplay had already abandoned for that iPad, OpenDisplay
// knew to skip them (the offset lives in its defaults), Design Canvas did not,
// and its whole three-probe budget went on displays that never came online.

import Foundation

extension SenderDisplayIdentity {
    /// "DC". Far below OpenDisplay's 0x4F53 so no run of abandoned identities
    /// on either side reaches the other's range.
    static let designCanvas = SenderDisplayIdentity(productIDBase: 0x4443, namePrefix: "Design Canvas")
}
