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

    /// What to do when a round of capture recovery left the stream down,
    /// `failures` rounds in a row. Extend gives up at `cap`: every round
    /// there is a virtual-display create/destroy, and ending the session
    /// beats hammering WindowServer forever. A mirror captures the Mac's
    /// own screen, which a lock or display sleep takes away for as long as
    /// the user is gone and which always comes back — so it only slows down.
    func recoveryStep(afterFailures failures: Int, cap: Int) -> CaptureRecoveryStep {
        if failures < cap { return .retry(after: 3) }
        return self == .mirror ? .retry(after: 30) : .endSession
    }
}

enum CaptureRecoveryStep: Equatable {
    case retry(after: TimeInterval)
    case endSession
}
