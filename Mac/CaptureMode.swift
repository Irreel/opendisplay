// What a sender captures. Its own file, Foundation only, so the choice of mode
// can be tested in the hostless bundles without MacSender's capture stack.

import Foundation

enum CaptureMode: String {
    case mirror   // main display (Milestone 1)
    case extend   // virtual display (Milestone 2)

    /// The mode to start in. A product that supports only one mode passes it
    /// as `fixed`, and nothing stored can select the other. Otherwise it is
    /// the user's choice — the `mode` default, which the `-mode mirror` /
    /// `-mode extend` launch argument also sets — and extend when there is
    /// none, or none that can be read.
    static func resolve(stored: String?, fixed: CaptureMode?) -> CaptureMode {
        fixed ?? stored.flatMap(CaptureMode.init(rawValue:)) ?? .extend
    }
}
