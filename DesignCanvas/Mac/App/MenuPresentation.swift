// What the menu says for each state: `DesignCanvas/spec/mac-app-ia.md` sections 4 to 6.
//
// A pure mapping, like `DisplayStateCopy`, so the D7 contract (every `DisplayState` stays
// distinguishable, every red state has a way out) is tested in `MenuPresentationTests` rather
// than read off a running menu. `MenuBarView` draws these rows; it decides nothing itself.
// The raw `DisplayState.statusText` strings stay for the Details window.

import Foundation

enum MenuTint: Equatable { case secondary, green, orange, red }

/// The trailing button on a row. The view maps each to an `AppModel` call.
enum RowAction: Equatable { case start, newSession, retry, disconnect, connect, grant, details }

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
        sessions: SessionsMessage = .empty,
        pendingUploads: Int,
        startBlocker: StartBlocker?
    ) -> RowPresentation {
        // The supervisor giving up is a dead end whatever the classifier says, so it wins.
        if daemonGaveUp {
            return RowPresentation(word: "Stopped", tint: .red, subline: "Stopped retrying", action: .retry)
        }
        var row = display == .ownedAttached ? connected(sessions) : base(display)
        if let blocker = startBlocker {
            if row.action == .start {
                row = RowPresentation(word: row.word, tint: row.tint, subline: blockerText(blocker), action: .start, actionEnabled: false)
            } else if row.action == .newSession {
                // Connected sessions keep their sub-line; only the button waits on a project.
                row.actionEnabled = false
            }
        }
        if pendingUploads > 0, row.subline == nil {
            return RowPresentation(word: row.word, tint: row.tint, subline: pendingText(pendingUploads),
                                   action: row.action, actionEnabled: row.actionEnabled)
        }
        return row
    }

    /// One or more sessions are connected (X21 to X26). The sub-line says where the next sketch
    /// goes, which is the one thing the user cannot see from the Terminal windows themselves.
    private static func connected(_ sessions: SessionsMessage) -> RowPresentation {
        guard let target = sessions.targetEntry else {
            if sessions.needsPick {
                return RowPresentation(word: "Choose one", tint: .orange,
                                       subline: "Pick which session gets sketches", action: .newSession)
            }
            // Connected by the daemon's count, with the list not read yet.
            return RowPresentation(word: "Connected", tint: .green, subline: nil, action: .newSession)
        }
        if target.state == .waiting {
            return RowPresentation(word: "Connected", tint: .green,
                                   subline: "Claude Code is waiting for you in the Terminal", action: .newSession)
        }
        let destination = "Sketches go to \(target.folder)"
        let subline = sessions.sessions.count > 1 ? "\(sessions.sessions.count) sessions \u{00B7} \(destination.prefix(1).lowercased() + destination.dropFirst())" : destination
        return RowPresentation(word: "Connected", tint: .green, subline: subline, action: .newSession)
    }

    /// What tells two sessions apart in the list (X25): the title when the user gave one, else
    /// when it started; then the branch and the last reply. `clock` turns the daemon's ISO time
    /// into a short local one, and is injected so the wording is testable.
    static func sessionDetail(_ entry: CanvasSessionEntry, clock: (String) -> String?) -> String {
        var parts: [String] = []
        if let title = entry.title {
            parts.append(title)
        } else if let started = clock(entry.startedAt) {
            parts.append("Started \(started)")
        }
        if let branch = entry.branch { parts.append(branch) }
        if let lastReplyAt = entry.lastReplyAt, let replied = clock(lastReplyAt) {
            parts.append("replied \(replied)")
        }
        return parts.joined(separator: " \u{00B7} ")
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
            return connected(.empty)
        case .existingSessionDetected:
            return RowPresentation(word: "Connected elsewhere", tint: .orange,
                                   subline: "Claude Code is connected to another copy of Design Canvas", action: .details)
        case .foreignDaemon:
            return RowPresentation(word: "Another instance", tint: .orange,
                                   subline: "Design Canvas is already running elsewhere", action: .details)
        case .portOccupiedUnknown:
            return RowPresentation(word: "Blocked", tint: .red,
                                   subline: "Another app is using Design Canvas's port", action: .details)
        }
    }

    /// X10: what to look for in the Terminal when a launch has not connected. The app cannot
    /// see inside Claude Code, so it names the causes it knows produce exactly this: the trust
    /// question (whose default answer is no), and an organisation that blocks plugins.
    static func launchHelp(_ display: DisplayState) -> String? {
        guard display == .launchTimedOut else { return nil }
        return "If Claude Code asks whether you trust the folder, choose Yes. If it says plugins are disabled by your organization, Design Canvas can't connect on this Mac."
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

    /// The sender's statuses are sentences ("Mirroring to device (2048×1536)", "Device found —
    /// open the OpenDisplay app on it…"). The row keeps a one-word state so the device name,
    /// not the state, is what survives a 320-point popover; the one sentence that tells the
    /// user to do something becomes the sub-line, in this app's words.
    static func deviceRow(_ device: EngineDevice) -> RowPresentation {
        let status = device.status
        let word: String
        var subline: String?
        if status.hasPrefix("Device found") {
            word = "Found"
            subline = "Open Design Canvas on the iPad"
        } else if status.hasPrefix("Waiting") {
            word = "Waiting\u{2026}"
        } else if status.hasPrefix("Mirroring") {
            word = "Mirroring"
        } else if status.hasPrefix("Extending") {
            word = "Extending"
        } else if status.hasPrefix("Connected") {
            word = "Connected"
        } else {
            word = status
        }
        return RowPresentation(word: word, tint: .green, subline: subline, action: .disconnect)
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
