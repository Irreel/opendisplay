import XCTest

/// Ported from ai.cst.2 `DesignCanvasDesktopTests/McpConfigManagerTests.swift`.
final class McpConfigManagerTests: XCTestCase {
    private func tempRepo() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeConfig(_ json: String, to repo: URL) throws {
        try json.write(to: repo.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
    }

    private func designCanvas(in repo: URL) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent(".mcp.json"))) as! [String: Any]
        return (json["mcpServers"] as! [String: Any])["design-canvas"] as! [String: Any]
    }

    func testCreatesEntryWhenAbsent() throws {
        let repo = tempRepo()
        let result = try McpConfigManager().ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        XCTAssertEqual(result, .created)
        XCTAssertEqual(try designCanvas(in: repo)["command"] as? String, "/usr/bin/node")
    }

    /// M9: `--channel` in the args is not enough. A project shared with, or carried over
    /// from, ai.cst.2 has a `design-canvas` entry naming *that* product's channel server —
    /// which would be spawned by Claude Code and would talk to a different daemon, or none.
    /// The entry must also point at the node path and server entry this app is configured
    /// with. `.needsUpdate` never rewrites anything by itself: the menu offers the explicit
    /// "Update .mcp.json entry" button.
    func testForeignChannelEntryNeedsUpdate() throws {
        let repo = tempRepo()
        try writeConfig(#"{"mcpServers":{"design-canvas":{"command":"designtool","args":["--channel"]}}}"#, to: repo)
        let result = try McpConfigManager().ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        XCTAssertEqual(result, .needsUpdate)
        // still not rewritten by ensureEntry — that is updateEntry's job
        XCTAssertEqual(try designCanvas(in: repo)["command"] as? String, "designtool")
    }

    /// The same server entry under a different node binary (a Homebrew upgrade, nvm) is
    /// also an update: Claude Code spawns the command in the file, not the one this app
    /// resolved.
    func testEntryWithADifferentNodePathNeedsUpdate() throws {
        let repo = tempRepo()
        try writeConfig(#"{"mcpServers":{"design-canvas":{"command":"/opt/homebrew/bin/node","args":["/srv/index.js","--channel"]}}}"#, to: repo)
        let result = try McpConfigManager().ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        XCTAssertEqual(result, .needsUpdate)
    }

    func testEntryWithADifferentServerEntryNeedsUpdate() throws {
        let repo = tempRepo()
        try writeConfig(#"{"mcpServers":{"design-canvas":{"command":"/usr/bin/node","args":["/elsewhere/index.js","--channel"]}}}"#, to: repo)
        let result = try McpConfigManager().ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        XCTAssertEqual(result, .needsUpdate)
    }

    func testMatchingEntryCompatible() throws {
        let repo = tempRepo()
        let mgr = McpConfigManager()
        _ = try mgr.ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        let again = try mgr.ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        XCTAssertEqual(again, .alreadyCompatible)
    }

    /// Order and extra arguments are the user's business: what matters is that Claude Code
    /// will spawn this node binary, on this server entry, in channel mode.
    func testMatchingEntryWithReorderedOrExtraArgsIsCompatible() throws {
        let repo = tempRepo()
        try writeConfig(#"{"mcpServers":{"design-canvas":{"command":"/usr/bin/node","args":["--channel","/srv/index.js","--verbose"]}}}"#, to: repo)
        let result = try McpConfigManager().ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        XCTAssertEqual(result, .alreadyCompatible)
        XCTAssertEqual(try designCanvas(in: repo)["args"] as? [String], ["--channel", "/srv/index.js", "--verbose"])
    }

    /// A stale entry from before the run-mode rename (`--mcp`) is flagged for update, not used.
    func testStaleEntryNeedsUpdate() throws {
        let repo = tempRepo()
        try writeConfig(#"{"mcpServers":{"design-canvas":{"command":"designtool","args":["--mcp"]}}}"#, to: repo)
        let result = try McpConfigManager().ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        XCTAssertEqual(result, .needsUpdate)
        // not rewritten by ensureEntry
        XCTAssertEqual(try designCanvas(in: repo)["args"] as? [String], ["--mcp"])
    }

    func testUpdateEntryOverwritesStaleAndPreservesOthers() throws {
        let repo = tempRepo()
        try writeConfig(#"{"mcpServers":{"design-canvas":{"command":"designtool","args":["--mcp"]},"other":{"command":"x"}}}"#, to: repo)
        try McpConfigManager().updateEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        let dc = try designCanvas(in: repo)
        XCTAssertEqual(dc["command"] as? String, "/usr/bin/node")
        XCTAssertEqual(dc["args"] as? [String], ["/srv/index.js", "--channel"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent(".mcp.json"))) as! [String: Any]
        XCTAssertNotNil((json["mcpServers"] as! [String: Any])["other"]) // unrelated server preserved
    }

    func testPreservesOtherServersOnCreate() throws {
        let repo = tempRepo()
        try writeConfig(#"{"mcpServers":{"other":{"command":"x"}}}"#, to: repo)
        _ = try McpConfigManager().ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent(".mcp.json"))) as! [String: Any]
        let servers = json["mcpServers"] as! [String: Any]
        XCTAssertNotNil(servers["other"])
        XCTAssertNotNil(servers["design-canvas"])
    }

    func testMalformedFileIsNotClobbered() throws {
        let repo = tempRepo()
        let path = repo.appendingPathComponent(".mcp.json")
        let original = "{ this is not valid json, mcpServers: important }"
        try original.write(to: path, atomically: true, encoding: .utf8)
        let mgr = McpConfigManager()
        XCTAssertThrowsError(try mgr.ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"]))
        let after = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(after, original) // file left untouched
    }

    /// Even the explicit-consent update must refuse (not clobber) a malformed file —
    /// it can't safely merge-preserve other servers it can't parse.
    func testUpdateEntryRefusesMalformedFile() throws {
        let repo = tempRepo()
        let path = repo.appendingPathComponent(".mcp.json")
        let original = "{ not valid json"
        try original.write(to: path, atomically: true, encoding: .utf8)
        let mgr = McpConfigManager()
        XCTAssertThrowsError(try mgr.updateEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"]))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), original) // untouched
    }

    /// A `design-canvas` entry with non-array `args` (or missing args) is treated as non-channel
    /// → `.needsUpdate`, never silently used or clobbered.
    func testNonArrayArgsNeedsUpdate() throws {
        let repo = tempRepo()
        try writeConfig(#"{"mcpServers":{"design-canvas":{"command":"designtool","args":"--channel"}}}"#, to: repo)
        let result = try McpConfigManager().ensureEntry(repoRoot: repo, command: "/usr/bin/node", args: ["/srv/index.js", "--channel"])
        XCTAssertEqual(result, .needsUpdate)
    }
}
