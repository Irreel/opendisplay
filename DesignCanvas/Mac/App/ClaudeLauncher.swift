// From ai.cst.2 `apps/desktop/DesignCanvasDesktop/ClaudeLauncher.swift`, changed for the Claude
// Code mod: the session is started with the mod that ships inside this app instead of the
// development-channels flag (X1), and Claude Code's version is checked first (X10).

import AppKit

/// What Start session launches: Claude Code in `repoRoot`, with the mod at `modDirectory`
/// loaded, carrying `nonce` so the session can say it was started here (X22's default target).
struct ClaudeLaunch: Equatable {
    let repoRoot: URL
    let modDirectory: String
    let nonce: String
}

/// A Claude Code version, as `claude --version` prints it ("2.1.289 (Claude Code)").
struct ClaudeVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// The first Claude Code with mods on by default. Raise it when the mod starts using
    /// something newer.
    static let minimumForMods = ClaudeVersion(major: 2, minor: 1, patch: 287)

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The first `a.b.c` in the text; nil when there is none.
    init?(parsing text: String) {
        guard let match = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        let parts = text[match].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(major: parts[0], minor: parts[1], patch: parts[2])
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

/// Whether Start session can go ahead, and the words for when it cannot (X10).
enum ClaudeAvailability: Equatable {
    case ok(ClaudeVersion)
    case notFound
    case tooOld(ClaudeVersion)

    /// `versionOutput` is what `claude --version` printed, or nil when it could not be run.
    init(versionOutput: String?) {
        guard let versionOutput, let version = ClaudeVersion(parsing: versionOutput) else {
            self = .notFound
            return
        }
        self = version < .minimumForMods ? .tooOld(version) : .ok(version)
    }

    var blockingMessage: String? {
        switch self {
        case .ok:
            return nil
        case .notFound:
            return "Claude Code was not found. Install it, check that `claude` runs in a new Terminal window, then start the session again."
        case .tooOld(let version):
            return "Claude Code \(version) is too old for Design Canvas, which needs \(ClaudeVersion.minimumForMods) or later. Run `claude update` in Terminal, then start the session again."
        }
    }
}

enum ClaudeLauncher {
    /// The shell command that launches Claude Code with the Design Canvas mod, in the given repo.
    /// The flag is passed even when the user has turned the mod on for every session: Claude
    /// Code loads a directory named twice once (spike, 2026-10-05), so there is no case to split.
    static func shellCommand(_ launch: ClaudeLaunch) -> String {
        "cd \(quote(launch.repoRoot.path)) && DESIGN_CANVAS_LAUNCH=\(quote(launch.nonce)) claude --plugin-dir \(quote(launch.modDirectory))"
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Launches the command in Terminal.app via AppleScript. Returns `nil` on success, or a
    /// human-readable error string on failure (e.g. Automation permission not granted).
    /// (Manual-verified — not unit-tested.)
    @discardableResult
    static func launchInTerminal(_ launch: ClaudeLaunch) -> String? {
        let command = shellCommand(launch)
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

    /// `claude --version` through the user's login shell, which is where `claude` is on PATH (a
    /// GUI app's own PATH rarely has it). Nil when it cannot be run. Blocks for the length of a
    /// shell start, so callers keep it off the main thread. (Manual-verified.)
    static func versionOutputFromLoginShell() -> String? {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "claude --version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
