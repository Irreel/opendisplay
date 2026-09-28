// What the menu says for each state: `DesignCanvas/spec/mac-app-ia.md` sections 4 to 6.
//
// A pure mapping, like `DisplayStateCopy`, so the D7 contract (every `DisplayState` stays
// distinguishable, every red state has a way out) is tested in `MenuPresentationTests` rather
// than read off a running menu. `MenuBarView` draws these rows; it decides nothing itself.
// The raw `DisplayState.statusText` strings stay for the Details window.

import Foundation

enum MenuTint: Equatable { case secondary, green, orange, red }

/// The trailing button on a row. The view maps each to an `AppModel` call.
enum RowAction: Equatable { case start, retry, disconnect, connect, grant, details }

/// Why Start is disabled even though the classifier would allow it.
enum StartBlocker: Equatable { case noProject, noServerBuild }

struct RowPresentation: Equatable {
    let word: String
    let tint: MenuTint
    let subline: String?
    let action: RowAction?
    var actionEnabled: Bool = true
}

enum MenuIcon: Equatable { case idle, ready, partial, attention }

enum MenuPresentation {

    // MARK: - Claude Code row (spec section 4)

    static func claudeCodeRow(
        display: DisplayState,
        daemonGaveUp: Bool,
        secondSubscriber: Bool,
        pendingUploads: Int,
        startBlocker: StartBlocker?
    ) -> RowPresentation {
        // The supervisor giving up is a dead end whatever the classifier says, so it wins.
        if daemonGaveUp {
            return RowPresentation(word: "Stopped", tint: .red, subline: "Stopped retrying", action: .retry)
        }
        var row = base(display)
        if let blocker = startBlocker, row.action == .start {
            row = RowPresentation(word: row.word, tint: row.tint, subline: blockerText(blocker), action: .start, actionEnabled: false)
        }
        // Warnings ride along as the sub-line, and never change the state word or the action.
        if secondSubscriber {
            return RowPresentation(word: row.word, tint: row.tint,
                                   subline: "Two sessions are attached; sketches may go to either",
                                   action: row.action, actionEnabled: row.actionEnabled)
        }
        if pendingUploads > 0, row.subline == nil {
            return RowPresentation(word: row.word, tint: row.tint, subline: pendingText(pendingUploads),
                                   action: row.action, actionEnabled: row.actionEnabled)
        }
        return row
    }

    private static func base(_ display: DisplayState) -> RowPresentation {
        switch display {
        case .noDaemon, .daemonOnly:
            return RowPresentation(word: "Not started", tint: .secondary, subline: nil, action: .start)
        case .launchPending:
            return RowPresentation(word: "Starting\u{2026}", tint: .orange,
                                   subline: "Waiting for Claude Code in the Terminal", action: nil)
        case .launchTimedOut:
            return RowPresentation(word: "Not connected", tint: .red, subline: "Check the Terminal window", action: .retry)
        case .ownedAttached:
            return RowPresentation(word: "Connected", tint: .green, subline: nil, action: .disconnect)
        case .existingSessionDetected:
            return RowPresentation(word: "Another session", tint: .orange,
                                   subline: "A Claude Code session this app didn't start is attached", action: .details)
        case .foreignDaemon:
            return RowPresentation(word: "Another instance", tint: .orange,
                                   subline: "Design Canvas is already running elsewhere", action: .details)
        case .portOccupiedUnknown:
            return RowPresentation(word: "Blocked", tint: .red,
                                   subline: "Another app is using Design Canvas's port", action: .details)
        }
    }

    private static func blockerText(_ blocker: StartBlocker) -> String {
        switch blocker {
        case .noProject: return "Choose a project first"
        case .noServerBuild: return "Set the server build in Settings"
        }
    }

    private static func pendingText(_ n: Int) -> String {
        n == 1 ? "1 sketch waiting to send" : "\(n) sketches waiting to send"
    }

    // MARK: - iPad rows (spec section 5)

    /// The single row shown when there is nothing to list: no permission, or no device at all.
    static func iPadPlaceholder(screenRecordingGranted: Bool) -> RowPresentation {
        if !screenRecordingGranted {
            return RowPresentation(word: "Needs permission", tint: .red,
                                   subline: "Design Canvas mirrors the screen. Takes effect after relaunch", action: .grant)
        }
        return RowPresentation(word: "Not connected", tint: .secondary,
                               subline: "Open Design Canvas on the iPad", action: nil)
    }

    static func deviceRow(_ device: EngineDevice) -> RowPresentation {
        RowPresentation(word: device.status, tint: .green, subline: nil, action: .disconnect)
    }

    static func discoveredRow(_ device: DiscoveredDevice) -> RowPresentation {
        RowPresentation(word: "Available", tint: .secondary, subline: nil, action: .connect)
    }

    // MARK: - Summary line (spec section 6)

    static func summary(screenRecordingGranted: Bool, iPadConnected: Bool, claude: RowPresentation) -> String {
        if !screenRecordingGranted { return "Screen Recording needed" }
        if claude.tint == .red { return claude.subline ?? claude.word }
        if !iPadConnected { return "Waiting for an iPad" }
        if claude.word == "Connected" { return "Ready \u{2014} sketches go to Claude Code" }
        return "Claude Code \u{2014} \(claude.word)"
    }

    // MARK: - Menu bar icon (spec section 3)

    static func icon(iPadConnected: Bool, claude: RowPresentation, screenRecordingGranted: Bool) -> MenuIcon {
        if !screenRecordingGranted || claude.tint == .red || (claude.subline?.hasSuffix("waiting to send") ?? false) {
            return .attention
        }
        let claudeConnected = claude.word == "Connected"
        switch (iPadConnected, claudeConnected) {
        case (true, true): return .ready
        case (false, false): return .idle
        default: return .partial
        }
    }
}
