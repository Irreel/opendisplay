import XCTest

/// Ported from ai.cst.2 `DesignCanvasDesktopTests/ClaudeLauncherTests.swift`.
final class ClaudeLauncherTests: XCTestCase {
    func testBuildsChannelCommand() {
        let cmd = ClaudeLauncher.shellCommand(repoRoot: URL(fileURLWithPath: "/Users/me/proj"))
        XCTAssertEqual(cmd, "cd '/Users/me/proj' && claude --dangerously-load-development-channels server:design-canvas")
    }

    func testQuotesPathWithSpaces() {
        let cmd = ClaudeLauncher.shellCommand(repoRoot: URL(fileURLWithPath: "/Users/me/my proj"))
        XCTAssertTrue(cmd.contains("'/Users/me/my proj'"))
    }
}
