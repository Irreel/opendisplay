// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/McpConfigManager.swift`, unchanged.

import Foundation

enum EnsureResult { case created, alreadyCompatible, needsUpdate }

enum McpConfigError: Error { case malformed(String) }

struct McpConfigManager {
    static let serverKey = "design-canvas"

    /// Decides what to do with the repo's `.mcp.json` `design-canvas` entry WITHOUT
    /// ever clobbering the user's existing config:
    /// - no entry → write ours → `.created`
    /// - entry that will spawn *this* app's channel — its `command` is the node path this
    ///   app resolved, its `args` include `--channel` and every argument we would pass
    ///   (the server entry) → use it as-is → `.alreadyCompatible` (no write). Order and
    ///   extra arguments are the user's business.
    /// - any other entry → `.needsUpdate` (no write) — the caller offers an explicit
    ///   `updateEntry`. That covers a stale run mode (`--mcp`/`--http-only`), non-array
    ///   `args`, and — the case that made this stricter (M9) — a `design-canvas` entry
    ///   from a *different* product with the same channel name, e.g. ai.cst.2's
    ///   `designtool --channel`. Claude Code spawns the command in the file, so such an
    ///   entry would attach some other channel server, talking to some other daemon or
    ///   none, while this app waits for a subscriber that never arrives.
    /// Throws `.malformed` if the file exists but isn't valid JSON (never overwrites it).
    func ensureEntry(repoRoot: URL, command: String, args: [String]) throws -> EnsureResult {
        let path = repoRoot.appendingPathComponent(".mcp.json")
        let root = try readRoot(at: path)
        let servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let existing = servers[Self.serverKey] as? [String: Any] {
            let existingArgs = existing["args"] as? [String] ?? []
            let isOurs = existing["command"] as? String == command
                && existingArgs.contains("--channel")
                && args.allSatisfy(existingArgs.contains)
            return isOurs ? .alreadyCompatible : .needsUpdate
        }
        try write(command: command, args: args, into: root, at: path)
        return .created
    }

    /// Overwrites the `design-canvas` entry with our command/args (preserving other servers).
    /// Used only when the user explicitly opts to fix a stale/non-channel entry.
    func updateEntry(repoRoot: URL, command: String, args: [String]) throws {
        let path = repoRoot.appendingPathComponent(".mcp.json")
        let root = try readRoot(at: path)
        try write(command: command, args: args, into: root, at: path)
    }

    // MARK: - Helpers

    /// Reads `.mcp.json` into a dictionary. Absent/empty → `[:]`. Non-empty but unparseable → throws.
    private func readRoot(at path: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: path), !data.isEmpty else { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else {
            throw McpConfigError.malformed(path.path) // never clobber a non-empty unparseable file
        }
        return dict
    }

    private func write(command: String, args: [String], into root: [String: Any], at path: URL) throws {
        var root = root
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.serverKey] = ["command": command, "args": args]
        root["mcpServers"] = servers
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: path, options: .atomic)
    }
}
