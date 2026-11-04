import XCTest

/// The daemon binds `127.0.0.1` and ignores `SERVER_HOST` (Task 6), so this is belt and braces:
/// the app strips an inherited `SERVER_HOST` before spawning, which makes "nothing this app
/// launches can be told to listen on the LAN" an asserted fact rather than a daemon-side promise.
final class DaemonEnvironmentTests: XCTestCase {
    func testSetsServerPort() {
        let env = DaemonEnvironment.make(base: [:], port: 47100)
        XCTAssertEqual(env["SERVER_PORT"], "47100")
    }

    func testOverwritesAnInheritedServerPort() {
        let env = DaemonEnvironment.make(base: ["SERVER_PORT": "9999"], port: 47100)
        XCTAssertEqual(env["SERVER_PORT"], "47100")
    }

    func testStripsAnInheritedServerHost() {
        let env = DaemonEnvironment.make(base: ["SERVER_HOST": "0.0.0.0"], port: 47100)
        XCTAssertNil(env["SERVER_HOST"], "an inherited SERVER_HOST must never reach the daemon")
    }

    func testKeepsEveryOtherInheritedVariable() {
        let env = DaemonEnvironment.make(base: ["PATH": "/usr/bin", "HOME": "/Users/me"], port: 47100)
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["HOME"], "/Users/me")
    }

    /// The daemon quits when the app's end of its stdin closes, so one left by a killed app
    /// cannot hold the port and stop the next launch's daemon from starting.
    func testAsksTheDaemonToExitWithTheApp() {
        let env = DaemonEnvironment.make(base: [:], port: 47100)
        XCTAssertEqual(env["DESIGN_CANVAS_EXIT_WITH_STDIN"], "1")
    }
}
