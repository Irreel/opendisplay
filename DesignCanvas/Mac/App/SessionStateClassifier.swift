// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/SessionStateClassifier.swift`.
// Only change: `Health` is now `DaemonHealth` (Task 8's `DaemonClient`), which has the same
// identity fields minus `pairedDevices`/`ipadUrls` — neither of which this classifier read.
//
// The rules themselves are ADR-0004's, unchanged: daemon identity is re-verified on every poll
// and a channel is "owned" only if this app run launched it while the count was 0.

import Foundation

// Daemon axis (rows) x channel axis (cols) -> display. "-" = channel axis doesn't
// apply (forced to .none) for that daemon row.
//                   .none            .launchPending      .owned          .existing
// .none             noDaemon         -                   -               -
// .unknownOccupant  portOccupiedUnknown (channel forced .none)
// .foreign          foreignDaemon    -                   -               existingSessionDetected
// .owned            daemonOnly       launchPending/           ownedAttached   existingSessionDetected
//                                    launchTimedOut

enum DaemonAxis: Equatable { case none, owned, foreign, unknownOccupant }
enum ChannelAxis: Equatable { case none, launchPending, owned, existing }
enum DisplayState: Equatable {
    case noDaemon, daemonOnly, launchPending, launchTimedOut,
         ownedAttached, existingSessionDetected, foreignDaemon, portOccupiedUnknown
}

struct SessionState: Equatable {
    let daemon: DaemonAxis
    let channel: ChannelAxis
    let display: DisplayState
    let canStart: Bool          // Start button gate
    let secondSubscriber: Bool  // channelCount > 1 warning
}

enum SessionStateClassifier {
    struct Input {
        let probe: HealthProbeResult
        let supervisedChildPid: Int32?   // pid of the daemon child the app spawned; nil if none
        let pinnedInstanceId: String?    // instanceId captured when the daemon was first seen owned
        let sessionStarted: Bool         // user clicked Start during THIS app run
        let launchTimedOut: Bool         // AppModel's ~60s launch timer expired
    }

    static func classify(_ input: Input) -> SessionState {
        let daemon = daemonAxis(input)
        let count = channelCount(input.probe)
        let channel = channelAxis(daemon: daemon, count: count, sessionStarted: input.sessionStarted)
        let display = displayState(daemon: daemon, channel: channel, launchTimedOut: input.launchTimedOut)
        let canStart = daemon == .owned && count == 0 && !input.sessionStarted
        let secondSubscriber = isHealthy(input.probe) && count > 1
        return SessionState(daemon: daemon, channel: channel, display: display, canStart: canStart, secondSubscriber: secondSubscriber)
    }

    private static func daemonAxis(_ input: Input) -> DaemonAxis {
        switch input.probe {
        case .refused:
            return .none
        case .timedOut, .badStatus, .foreignResponse:
            return .unknownOccupant
        case .healthy(let h):
            guard let pid = h.pid else { return .foreign }
            guard let childPid = input.supervisedChildPid, pid == Int(childPid) else { return .foreign }
            if let pinned = input.pinnedInstanceId, pinned != h.instanceId { return .foreign }
            return .owned
        }
    }

    static func channelCount(_ probe: HealthProbeResult) -> Int {
        guard case .healthy(let h) = probe else { return 0 }
        return h.channelCount ?? (h.channelAttached ? 1 : 0)
    }

    private static func channelAxis(daemon: DaemonAxis, count: Int, sessionStarted: Bool) -> ChannelAxis {
        switch daemon {
        case .none, .unknownOccupant:
            return .none
        case .owned, .foreign:
            if count == 0 { return sessionStarted ? .launchPending : .none }
            if sessionStarted && daemon == .owned { return .owned }
            return .existing
        }
    }

    private static func displayState(daemon: DaemonAxis, channel: ChannelAxis, launchTimedOut: Bool) -> DisplayState {
        switch daemon {
        case .none:
            return .noDaemon
        case .unknownOccupant:
            return .portOccupiedUnknown
        case .foreign:
            return channel == .existing ? .existingSessionDetected : .foreignDaemon
        case .owned:
            switch channel {
            case .none: return .daemonOnly
            case .launchPending: return launchTimedOut ? .launchTimedOut : .launchPending
            case .owned: return .ownedAttached
            case .existing: return .existingSessionDetected
            }
        }
    }

    private static func isHealthy(_ probe: HealthProbeResult) -> Bool {
        if case .healthy = probe { return true }
        return false
    }
}

extension ChannelState {
    /// The iPad's channel dot (`ping.channel`) is the menu's own verdict, so the two can never
    /// disagree: a channel this app run launched is `attached`; one it didn't is `existing`
    /// ("Another session" on the Mac), whichever daemon holds it; a daemon with no channel,
    /// including one whose Claude Code is still launching, is `detached`; no usable daemon is
    /// `none`.
    init(session: SessionState) {
        switch session.daemon {
        case .none, .unknownOccupant:
            self = .none
        case .owned, .foreign:
            switch session.channel {
            case .owned: self = .attached
            case .existing: self = .existing
            case .none, .launchPending: self = .detached
            }
        }
    }
}
