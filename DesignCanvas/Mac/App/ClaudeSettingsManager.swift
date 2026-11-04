// "Use Design Canvas in every Claude Code session" (X20), which is one entry in the user's own
// Claude Code settings: this app's mod directory in `CLAUDE_CODE_PLUGIN_DIRS`, under `env` in
// `~/.claude/settings.json`. Claude Code documents that variable for exactly this, "plugin
// directories to load as --plugin-dir does, for apps you can't pass a flag to".
//
// The file is the user's. So, the rules `McpConfigManager` had for a project's `.mcp.json`:
// change one value, keep every other key, write atomically, and never rewrite a file that does
// not parse. Turning the option off removes exactly what turning it on added.

import Foundation

enum ClaudeSettingsError: Error, Equatable {
    /// The file exists and is not a JSON object. It is left untouched.
    case malformed(String)
}

struct ClaudeSettingsManager {
    static let variable = "CLAUDE_CODE_PLUGIN_DIRS"

    let settingsURL: URL

    init(settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")) {
        self.settingsURL = settingsURL
    }

    /// The plugin directories the settings file lists, in order.
    func directories() throws -> [String] {
        Self.directories(in: try readRoot())
    }

    func contains(_ directory: String) -> Bool {
        ((try? directories()) ?? []).contains(directory)
    }

    /// Lists `directory`, after dropping `replacing` (the path this app registered before it was
    /// moved). Other entries keep their place. No write when nothing would change.
    func add(_ directory: String, replacing old: String? = nil) throws {
        let root = try readRoot()
        var dirs = Self.directories(in: root)
        if let old, old != directory { dirs.removeAll { $0 == old } }
        if !dirs.contains(directory) { dirs.append(directory) }
        guard dirs != Self.directories(in: root) else { return }
        try write(Self.setting(dirs, in: root))
    }

    /// Unlists `directory`; removes the variable when it was the last entry, and `env` when that
    /// was its last key. A missing file or entry is not an error and causes no write.
    func remove(_ directory: String) throws {
        let root = try readRoot()
        let dirs = Self.directories(in: root)
        guard dirs.contains(directory) else { return }
        try write(Self.setting(dirs.filter { $0 != directory }, in: root))
    }

    // MARK: - Pure helpers

    static func directories(in root: [String: Any]) -> [String] {
        guard let env = root["env"] as? [String: Any], let value = env[variable] as? String else { return [] }
        return value.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    static func setting(_ directories: [String], in root: [String: Any]) -> [String: Any] {
        var root = root
        var env = root["env"] as? [String: Any] ?? [:]
        if directories.isEmpty {
            env.removeValue(forKey: variable)
        } else {
            env[variable] = directories.joined(separator: ":")
        }
        if env.isEmpty {
            root.removeValue(forKey: "env")
        } else {
            root["env"] = env
        }
        return root
    }

    // MARK: - File

    /// Absent or empty → `[:]`. Non-empty but not a JSON object → throws, so it is never clobbered.
    private func readRoot() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else {
            throw ClaudeSettingsError.malformed(settingsURL.path)
        }
        return dict
    }

    private func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }
}
