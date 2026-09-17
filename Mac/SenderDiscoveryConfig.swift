// How a sender finds and dials its devices.
//
// Split out of `SenderControllerConfig` so it can be compiled into a hostless
// test bundle: the rest of that config names `DeviceSession` and
// `AppPresentation`, which drag in AppKit and the whole capture stack, while
// these two values are the ones a second product actually has to change.
//
// Foundation only, and no reference to any other type here.

import Foundation

/// The service a sender browses for and the port it dials.
///
/// The defaults are OpenDisplay's: changing nothing keeps the behaviour that
/// shipped. Design Canvas overrides both — it advertises its own Bonjour type
/// and listens on its own port, which is what stops the two products from
/// dialing each other over USB, where there is no service type to tell them
/// apart (plan ruling 1).
struct SenderDiscoveryConfig {
    /// The Bonjour service type browsed for WiFi devices.
    var bonjourType = "_opensidecar._tcp"
    /// The port used for USB dialing, and the default for WiFi.
    var devicePort: UInt16 = 9000
}
