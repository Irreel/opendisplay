import XCTest

/// The menu's words, tints and actions per state — `DesignCanvas/spec/mac-app-ia.md` sections
/// 4 to 6. Pure mapping, so the D7 contract ("every DisplayState stays distinguishable") is
/// checked here rather than by eye.
final class MenuPresentationTests: XCTestCase {

    private func claude(
        _ display: DisplayState,
        daemonGaveUp: Bool = false,
        secondSubscriber: Bool = false,
        pendingUploads: Int = 0,
        startBlocker: StartBlocker? = nil
    ) -> RowPresentation {
        MenuPresentation.claudeCodeRow(
            display: display,
            daemonGaveUp: daemonGaveUp,
            secondSubscriber: secondSubscriber,
            pendingUploads: pendingUploads,
            startBlocker: startBlocker
        )
    }

    // MARK: - Claude Code row (section 4)

    func testNotStartedOffersStart() {
        let row = claude(.noDaemon)
        XCTAssertEqual(row.word, "Not started")
        XCTAssertEqual(row.tint, .secondary)
        XCTAssertNil(row.subline)
        XCTAssertEqual(row.action, .start)
        XCTAssertTrue(row.actionEnabled)
    }

    func testDaemonOnlyReadsTheSameAsNoDaemon() {
        XCTAssertEqual(claude(.daemonOnly), claude(.noDaemon))
    }

    func testStartingHasNoAction() {
        let row = claude(.launchPending)
        XCTAssertEqual(row.word, "Starting\u{2026}")
        XCTAssertEqual(row.tint, .orange)
        XCTAssertEqual(row.subline, "Waiting for Claude Code in the Terminal")
        XCTAssertNil(row.action)
    }

    func testTimedOutIsRedAndOffersRetry() {
        let row = claude(.launchTimedOut)
        XCTAssertEqual(row.word, "Not connected")
        XCTAssertEqual(row.tint, .red)
        XCTAssertEqual(row.subline, "Check the Terminal window")
        XCTAssertEqual(row.action, .retry)
    }

    func testConnectedOffersDisconnect() {
        let row = claude(.ownedAttached)
        XCTAssertEqual(row.word, "Connected")
        XCTAssertEqual(row.tint, .green)
        XCTAssertNil(row.subline)
        XCTAssertEqual(row.action, .disconnect)
    }

    func testPendingSketchesBecomeTheSubline() {
        XCTAssertEqual(claude(.ownedAttached, pendingUploads: 1).subline, "1 sketch waiting to send")
        XCTAssertEqual(claude(.ownedAttached, pendingUploads: 3).subline, "3 sketches waiting to send")
    }

    func testExistingSessionPointsToDetails() {
        let row = claude(.existingSessionDetected)
        XCTAssertEqual(row.word, "Another session")
        XCTAssertEqual(row.tint, .orange)
        XCTAssertEqual(row.subline, "A Claude Code session this app didn't start is attached")
        XCTAssertEqual(row.action, .details)
    }

    func testForeignDaemonPointsToDetails() {
        let row = claude(.foreignDaemon)
        XCTAssertEqual(row.word, "Another instance")
        XCTAssertEqual(row.tint, .orange)
        XCTAssertEqual(row.action, .details)
    }

    func testPortOccupiedIsBlocked() {
        let row = claude(.portOccupiedUnknown)
        XCTAssertEqual(row.word, "Blocked")
        XCTAssertEqual(row.tint, .red)
        XCTAssertEqual(row.subline, "Another app is using Design Canvas's port")
        XCTAssertEqual(row.action, .details)
    }

    func testGaveUpOverridesTheState() {
        let row = claude(.noDaemon, daemonGaveUp: true)
        XCTAssertEqual(row.word, "Stopped")
        XCTAssertEqual(row.tint, .red)
        XCTAssertEqual(row.subline, "Stopped retrying")
        XCTAssertEqual(row.action, .retry)
    }

    func testSecondSubscriberWarnsButKeepsTheAction() {
        let row = claude(.ownedAttached, secondSubscriber: true, pendingUploads: 2)
        XCTAssertEqual(row.word, "Connected")
        XCTAssertEqual(row.subline, "Two sessions are attached; sketches may go to either")
        XCTAssertEqual(row.action, .disconnect)
    }

    func testStartBlockerDisablesStartAndSaysWhy() {
        let noProject = claude(.daemonOnly, startBlocker: .noProject)
        XCTAssertEqual(noProject.action, .start)
        XCTAssertFalse(noProject.actionEnabled)
        XCTAssertEqual(noProject.subline, "Choose a project first")
        XCTAssertEqual(claude(.daemonOnly, startBlocker: .noServerBuild).subline, "Set the server build in Settings")
    }

    func testEveryDisplayStateStaysDistinguishable() {
        let all: [DisplayState] = [.noDaemon, .daemonOnly, .launchPending, .launchTimedOut,
                                   .ownedAttached, .existingSessionDetected, .foreignDaemon, .portOccupiedUnknown]
        let rows = all.map { claude($0) }
        // noDaemon and daemonOnly are the one pair that reads the same by design.
        XCTAssertEqual(Set(rows.map { "\($0.word)|\($0.subline ?? "")" }).count, all.count - 1)
    }

    // MARK: - iPad row (section 5)

    func testMissingScreenRecordingReplacesTheDeviceRows() {
        let row = MenuPresentation.iPadPlaceholder(screenRecordingGranted: false)
        XCTAssertEqual(row.word, "Needs permission")
        XCTAssertEqual(row.tint, .red)
        XCTAssertEqual(row.action, .grant)
    }

    func testNoDevicesTellsTheUserWhatToDo() {
        let row = MenuPresentation.iPadPlaceholder(screenRecordingGranted: true)
        XCTAssertEqual(row.word, "Not connected")
        XCTAssertEqual(row.tint, .secondary)
        XCTAssertEqual(row.subline, "Open Design Canvas on the iPad")
        XCTAssertNil(row.action)
    }

    func testConnectedDeviceKeepsTheEngineStatus() {
        let row = MenuPresentation.deviceRow(EngineDevice(id: "d1", name: "Amy's iPad", status: "Streaming", onUSB: true))
        XCTAssertEqual(row.word, "Streaming")
        XCTAssertEqual(row.tint, .green)
        XCTAssertEqual(row.action, .disconnect)
    }

    func testDiscoveredDeviceIsAvailable() {
        let row = MenuPresentation.discoveredRow(DiscoveredDevice(id: "d2", name: "Studio iPad", transport: "WiFi"))
        XCTAssertEqual(row.word, "Available")
        XCTAssertEqual(row.tint, .secondary)
        XCTAssertEqual(row.action, .connect)
    }

    // MARK: - Summary line (section 6)

    func testSummaryReadyWhenBothHopsAreUp() {
        XCTAssertEqual(
            MenuPresentation.summary(screenRecordingGranted: true, iPadConnected: true, claude: claude(.ownedAttached)),
            "Ready \u{2014} sketches go to Claude Code"
        )
    }

    func testSummaryWaitsForAnIPad() {
        XCTAssertEqual(
            MenuPresentation.summary(screenRecordingGranted: true, iPadConnected: false, claude: claude(.ownedAttached)),
            "Waiting for an iPad"
        )
        XCTAssertEqual(
            MenuPresentation.summary(screenRecordingGranted: true, iPadConnected: false, claude: claude(.noDaemon)),
            "Waiting for an iPad"
        )
    }

    func testSummaryNamesTheClaudeCodeStateWhenTheIPadIsUp() {
        XCTAssertEqual(
            MenuPresentation.summary(screenRecordingGranted: true, iPadConnected: true, claude: claude(.noDaemon)),
            "Claude Code \u{2014} Not started"
        )
    }

    func testSummaryPriorityIsPermissionThenRedStates() {
        XCTAssertEqual(
            MenuPresentation.summary(screenRecordingGranted: false, iPadConnected: true, claude: claude(.launchTimedOut)),
            "Screen Recording needed"
        )
        XCTAssertEqual(
            MenuPresentation.summary(screenRecordingGranted: true, iPadConnected: false, claude: claude(.launchTimedOut)),
            "Check the Terminal window"
        )
    }

    // MARK: - Menu bar icon (section 3)

    func testIconStates() {
        XCTAssertEqual(MenuPresentation.icon(iPadConnected: false, claude: claude(.noDaemon), screenRecordingGranted: true), .idle)
        XCTAssertEqual(MenuPresentation.icon(iPadConnected: true, claude: claude(.ownedAttached), screenRecordingGranted: true), .ready)
        XCTAssertEqual(MenuPresentation.icon(iPadConnected: true, claude: claude(.noDaemon), screenRecordingGranted: true), .partial)
        XCTAssertEqual(MenuPresentation.icon(iPadConnected: true, claude: claude(.launchTimedOut), screenRecordingGranted: true), .attention)
        XCTAssertEqual(MenuPresentation.icon(iPadConnected: true, claude: claude(.ownedAttached, pendingUploads: 1), screenRecordingGranted: true), .attention)
        XCTAssertEqual(MenuPresentation.icon(iPadConnected: false, claude: claude(.noDaemon), screenRecordingGranted: false), .attention)
    }
}
