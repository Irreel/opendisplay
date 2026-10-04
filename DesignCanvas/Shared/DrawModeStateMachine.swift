import Foundation

/// Pure state machine for Draw Mode: freezing the live frame, drawing an
/// annotation over it, sending it, and retrying after a link loss. Holds no
/// I/O of its own — callers perform the returned `Effect`s.
struct DrawModeStateMachine {
    enum State: Equatable {
        case live
        case freezing(deadline: TimeInterval)
        case drawing
        case sending
        case retry
    }

    enum Event: Equatable {
        case enterDrawMode(now: TimeInterval)
        /// Draw Mode on the blank canvas surface: there is no frame to hold,
        /// so nothing is asked of the Mac and DRAWING starts at once.
        case enterBlankDrawMode
        case frozen(ok: Bool)
        case tick(now: TimeInterval)
        case strokeCountChanged(Int)
        case done
        case cancel
        case discard
        case sent
        case linkLost
        case rotated
        case helloReceived
    }

    enum Notice: Equatable {
        case noFrame
        case freezeTimedOut
        case interruptedByRotation
        case interruptedByLinkLoss
        /// The sketch would not fit in one canvas frame (M10). Draw Mode stays
        /// open: the designer still has the strokes and can erase some.
        case sketchTooLarge
    }

    enum Effect: Equatable {
        case pauseSync
        case resumeSync
        case sendFreeze
        case sendAnnotation
        case clearStrokes
        case show(Notice)
    }

    static let freezeTimeout: TimeInterval = 2

    private(set) var state: State = .live
    private(set) var strokeCount = 0

    var canSend: Bool {
        state == .drawing && strokeCount > 0
    }

    var isInDrawMode: Bool {
        switch state {
        case .freezing, .drawing:
            return true
        case .live, .sending, .retry:
            return false
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        // strokeCountChanged is recorded from any state and never changes it.
        if case .strokeCountChanged(let n) = event {
            strokeCount = max(0, n)
            return []
        }

        switch (state, event) {
        case (.live, .enterDrawMode(let now)):
            state = .freezing(deadline: now + Self.freezeTimeout)
            return [.pauseSync, .sendFreeze]

        // No `pauseSync`: the picture is not what is being drawn on. The exits
        // from DRAWING still say `resumeSync`, which is a no-op on a receiver
        // that was never frozen.
        case (.live, .enterBlankDrawMode):
            state = .drawing
            return []

        case (.freezing, .frozen(true)):
            state = .drawing
            return []

        case (.freezing, .frozen(false)):
            state = .live
            return [.resumeSync, .show(.noFrame)]

        case (.freezing(let deadline), .tick(let now)):
            guard now >= deadline else { return [] }
            state = .live
            return [.resumeSync, .show(.freezeTimedOut)]

        case (.freezing, .cancel), (.drawing, .cancel):
            state = .live
            return [.resumeSync]

        case (.freezing, .discard), (.drawing, .discard):
            state = .live
            return [.resumeSync, .clearStrokes]

        case (.freezing, .rotated), (.drawing, .rotated):
            state = .live
            return [.resumeSync, .show(.interruptedByRotation)]

        case (.freezing, .linkLost), (.drawing, .linkLost):
            state = .live
            return [.resumeSync, .show(.interruptedByLinkLoss)]

        case (.drawing, .done):
            guard strokeCount >= 1 else { return [] }
            state = .sending
            return [.sendAnnotation, .resumeSync]

        case (.sending, .sent):
            state = .live
            return [.clearStrokes]

        case (.sending, .linkLost):
            state = .retry
            return []

        case (.retry, .helloReceived):
            state = .sending
            return [.sendAnnotation]

        // The only way out of RETRY other than a reconnect (M10). Without it a
        // device that will not reconnect soon — the Mac app was quit, the
        // designer left the network — sat with Draw disabled and "Sketch kept —
        // will resend" for ever. No `resumeSync`: leaving DRAWING for SENDING
        // already let the picture run.
        case (.retry, .discard):
            state = .live
            return [.clearStrokes]

        default:
            return []
        }
    }
}
