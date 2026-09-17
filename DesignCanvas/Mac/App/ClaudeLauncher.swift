// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/ClaudeLauncher.swift`, unchanged.

import AppKit

enum ClaudeLauncher {
    /// The shell command that launches Claude Code with the channel attached, in the given repo.
    static func shellCommand(repoRoot: URL) -> String {
        let quoted = "'" + repoRoot.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) && claude --dangerously-load-development-channels server:design-canvas"
    }

    /// Launches the command in Terminal.app via AppleScript. Returns `nil` on success, or a
    /// human-readable error string on failure (e.g. Automation permission not granted).
    /// (Manual-verified — not unit-tested.)
    @discardableResult
    static func launchInTerminal(repoRoot: URL) -> String? {
        let command = shellCommand(repoRoot: repoRoot)
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\"\ntell application \"Terminal\" to activate"
        guard let appleScript = NSAppleScript(source: script) else {
            return "Couldn't build the Terminal launch script."
        }
        var err: NSDictionary?
        appleScript.executeAndReturnError(&err)
        if let err {
            let message = err[NSAppleScript.errorMessage] as? String ?? "unknown error"
            return "Couldn't open Terminal: \(message). Grant Automation access in System Settings → Privacy & Security → Automation."
        }
        return nil
    }
}
