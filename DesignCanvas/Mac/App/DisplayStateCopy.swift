// From ai.cst.2 `apps/desktop/DesignCanvasDesktop/DisplayStateCopy.swift`; the two connected
// states reworded for sessions that connect through the Claude Code mod.

import SwiftUI

/// Status copy shown in the menu for each `DisplayState`. Kept as a pure, testable mapping
/// separate from `SessionStateClassifier` so the classifier stays UI-framework free;
/// `MenuBarView` reads these instead of composing copy from raw health fields.
extension DisplayState {
    var statusText: String {
        switch self {
        case .ownedAttached:
            return "\u{25CF} Claude Code connected"
        case .launchPending:
            return "Launched \u{2014} waiting for Claude Code\u{2026}"
        case .launchTimedOut:
            return "Claude Code didn't connect \u{2014} check the Terminal window"
        case .existingSessionDetected:
            return "Claude Code is connected to another Design Canvas instance"
        case .daemonOnly:
            return "No session running"
        case .noDaemon:
            return "Daemon: down"
        case .foreignDaemon:
            return "Existing Design Canvas daemon detected"
        case .portOccupiedUnknown:
            return "Port 47100 is in use by an unknown process"
        }
    }

    var statusTint: Color {
        switch self {
        case .ownedAttached:
            return .green
        case .launchPending:
            return .orange
        case .launchTimedOut:
            return .red
        case .existingSessionDetected:
            return .orange
        case .daemonOnly:
            return .secondary
        case .noDaemon:
            return .red
        case .foreignDaemon:
            return .orange
        case .portOccupiedUnknown:
            return .red
        }
    }
}
