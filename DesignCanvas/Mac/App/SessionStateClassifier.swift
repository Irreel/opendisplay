// From ai.cst.2 `apps/desktop/DesignCanvasDesktop/SessionStateClassifier.swift`, reshaped for
// the Claude Code mod (`spec/technical_doc-ClaudeMods.md` section 6.2).
//
// The daemon axis is ADR-0004's, unchanged: daemon identity is re-verified on every poll. The
// other axis used to ask whether a *channel* was attached and whether this app run had launched
// it, because a channel the app did not launch could not be used. A session connected through
// the mod can be used whoever started it (X9), so that axis now only asks whether any session
// is connected, and "started here" survives as one thing: a launch that has not arrived yet.

import Foundation

// Daemon axis (rows) x session axis (cols) -> display. "-" = the session axis doesn't apply
// (forced to .none) for that daemon row.
//                   .none            .launchPending      .connected
// .none             noDaemon         -                   -
// .unknownOccupant  portOccupiedUnknown (session axis forced .none)
// .foreign          foreignDaemon    foreignDaemon       existingSessionDetected
// .owned            daemonOnly       launchPending/      ownedAttached
//                                    launchTimedOut

enum DaemonAxis: Equatable { case none, owned, foreign, unknownOccupant }
enum ChannelAxis: Equatable { case none, launchPending, connected }
enum DisplayState: Equatable {
    case noDaemon, daemonOnly, launchPending, launchTimedOut,
         ownedAttached, existingSessionDetected, foreignDaemon, portOccupiedUnknown
}

struct SessionState: Equatable {
    let daemon: DaemonAxis
    let channel: ChannelAxis
    let display: DisplayState
    let canStart: Bool          // Start button gate
}

enum SessionStateClassifier {
    struct Input {
        let probe: HealthProbeResult
        let supervisedChildPid: Int32?   // pid of the daemon child the app spawned; nil if none
        let pinnedInstanceId: String?    // instanceId captured when the daemon was first seen owned
        let sessionStarted: Bool         // a launch from this app is on its way and has not arrived
        let launchTimedOut: Bool         // AppModel's ~60s launch timer expired
    }

    static func classify(_ input: Input) -> SessionState {
        let daemon = daemonAxis(input)
        let count = sessionCount(input.probe)
        let channel = channelAxis(daemon: daemon, count: count, sessionStarted: input.sessionStarted)
        let display = displayState(daemon: daemon, channel: channel, launchTimedOut: input.launchTimedOut)
        // Another session can always be started beside the connected ones (X18 allows several);
        // only a launch already in flight holds the button.
        let canStart = daemon == .owned && !input.sessionStarted
        return SessionState(daemon: daemon, channel: channel, display: display, canStart: canStart)
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

    /// Claude Code sessions connected through the mod. A daemon that predates the mod reports
    /// none, whatever its channel count says: a channel is not a session.
    static func sessionCount(_ probe: HealthProbeResult) -> Int {
        guard case .healthy(let h) = probe else { return 0 }
        return h.sessionCount ?? 0
    }

    private static func channelAxis(daemon: DaemonAxis, count: Int, sessionStarted: Bool) -> ChannelAxis {
        switch daemon {
        case .none, .unknownOccupant:
            return .none
        case .owned, .foreign:
            if count > 0 { return .connected }
            return sessionStarted ? .launchPending : .none
        }
    }

    private static func displayState(daemon: DaemonAxis, channel: ChannelAxis, launchTimedOut: Bool) -> DisplayState {
        switch daemon {
        case .none:
            return .noDaemon
        case .unknownOccupant:
            return .portOccupiedUnknown
        case .foreign:
            // Sessions are connected, but to a daemon this app does not run: its sketches
            // cannot reach them.
            return channel == .connected ? .existingSessionDetected : .foreignDaemon
        case .owned:
            switch channel {
            case .none: return .daemonOnly
            case .launchPending: return launchTimedOut ? .launchTimedOut : .launchPending
            case .connected: return .ownedAttached
            }
        }
    }
}

extension ChannelState {
    /// The iPad's dot (`ping.channel`) is the menu's own verdict, so the two can never disagree:
    /// `attached` when a session is connected to this app's daemon; `detached` for a daemon
    /// with no session this app can reach, including one whose Claude Code is still launching;
    /// `none` for no usable daemon. `existing` named a session the app did not start and could
    /// not use; with the mod there is no such thing, so it is no longer sent.
    init(session: SessionState) {
        switch session.daemon {
        case .none, .unknownOccupant:
            self = .none
        case .foreign:
            self = .detached
        case .owned:
            self = session.channel == .connected ? .attached : .detached
        }
    }
}
