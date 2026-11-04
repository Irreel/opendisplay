import XCTest

/// From ai.cst.2 `DesignCanvasDesktopTests/ClaudeLauncherTests.swift`, rewritten for the mod
/// launch (X1) and the version check in front of it (X10).
final class ClaudeLauncherTests: XCTestCase {
    private func launch(_ repo: String, mod: String = "/Applications/Design Canvas.app/Contents/Resources/mod", nonce: String = "N-1") -> ClaudeLaunch {
        ClaudeLaunch(repoRoot: URL(fileURLWithPath: repo), modDirectory: mod, nonce: nonce)
    }

    func testBuildsTheModCommandWithNoDevelopmentFlag() {
        let cmd = ClaudeLauncher.shellCommand(launch("/Users/me/proj"))
        XCTAssertEqual(
            cmd,
            "cd '/Users/me/proj' && DESIGN_CANVAS_LAUNCH='N-1' claude --plugin-dir '/Applications/Design Canvas.app/Contents/Resources/mod'"
        )
        XCTAssertFalse(cmd.contains("dangerously"), "no development flag (X1)")
        XCTAssertFalse(cmd.contains("channels"))
    }

    func testQuotesPathsWithSpacesAndQuotes() {
        let cmd = ClaudeLauncher.shellCommand(launch("/Users/me/my proj", mod: "/Apps/Bob's/mod"))
        XCTAssertTrue(cmd.contains("cd '/Users/me/my proj' &&"))
        XCTAssertTrue(cmd.contains(#"--plugin-dir '/Apps/Bob'\''s/mod'"#), cmd)
    }

    func testParsesWhatClaudePrints() {
        XCTAssertEqual(ClaudeVersion(parsing: "2.1.289 (Claude Code)"), ClaudeVersion(major: 2, minor: 1, patch: 289))
        XCTAssertEqual(ClaudeVersion(parsing: "warning: something\n10.0.3\n"), ClaudeVersion(major: 10, minor: 0, patch: 3))
        XCTAssertNil(ClaudeVersion(parsing: "command not found: claude"))
        XCTAssertNil(ClaudeVersion(parsing: ""))
    }

    func testComparesVersionsNumericallyNotAsText() {
        XCTAssertLessThan(ClaudeVersion(major: 2, minor: 1, patch: 99), ClaudeVersion(major: 2, minor: 1, patch: 287))
        XCTAssertLessThan(ClaudeVersion(major: 2, minor: 1, patch: 287), ClaudeVersion(major: 2, minor: 2, patch: 0))
        XCTAssertLessThan(ClaudeVersion(major: 2, minor: 9, patch: 0), ClaudeVersion(major: 10, minor: 0, patch: 0))
    }

    func testAvailabilitySaysWhatIsWrongAndWhatToDo() {
        XCTAssertNil(ClaudeAvailability(versionOutput: "2.1.287 (Claude Code)").blockingMessage, "the minimum itself is enough")
        XCTAssertNil(ClaudeAvailability(versionOutput: "3.0.0").blockingMessage)

        let old = ClaudeAvailability(versionOutput: "2.1.286 (Claude Code)")
        XCTAssertEqual(old, .tooOld(ClaudeVersion(major: 2, minor: 1, patch: 286)))
        XCTAssertTrue(old.blockingMessage?.contains("2.1.286") ?? false)
        XCTAssertTrue(old.blockingMessage?.contains("claude update") ?? false, "says what to do")

        let missing = ClaudeAvailability(versionOutput: nil)
        XCTAssertEqual(missing, .notFound)
        XCTAssertTrue(missing.blockingMessage?.contains("not found") ?? false)
        XCTAssertEqual(ClaudeAvailability(versionOutput: "zsh: command not found: claude"), .notFound)
    }
}
