import XCTest

/// The menu's words, tints and actions per state — `DesignCanvas/spec/mac-app-ia.md` sections
/// 4 to 6. Pure mapping, so the D7 contract ("every DisplayState stays distinguishable") is
/// checked here rather than by eye.
final class MenuPresentationTests: XCTestCase {

    private func claude(
        _ display: DisplayState,
        daemonGaveUp: Bool = false,
        sessions: SessionsMessage = .empty,
        pendingUploads: Int = 0,
        startBlocker: StartBlocker? = nil
    ) -> RowPresentation {
        MenuPresentation.claudeCodeRow(
            display: display,
            daemonGaveUp: daemonGaveUp,
            sessions: sessions,
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
        let help = MenuPresentation.launchHelp(.launchTimedOut)
        XCTAssertTrue(help?.contains("trust the folder") ?? false, "X10: the trust question, whose default is no")
        XCTAssertTrue(help?.contains("organization") ?? false, "X10: the block an organisation can set")
        XCTAssertNil(MenuPresentation.launchHelp(.launchPending))
        XCTAssertNil(MenuPresentation.launchHelp(.ownedAttached))
    }

    private func entry(_ id: String, folder: String, title: String? = nil, branch: String? = nil,
                       lastReplyAt: String? = nil, state: CanvasSessionState = .idle) -> CanvasSessionEntry {
        CanvasSessionEntry(id: id, folder: folder, title: title, branch: branch,
                           startedAt: "2026-10-05T10:00:00.000Z", lastReplyAt: lastReplyAt, state: state)
    }

    func testConnectedOffersANewSessionNotADisconnect() {
        let row = claude(.ownedAttached)
        XCTAssertEqual(row.word, "Connected")
        XCTAssertEqual(row.tint, .green)
        XCTAssertNil(row.subline)
        XCTAssertEqual(row.action, .newSession, "a session ends in its Terminal; the app can only start another")
    }

    func testConnectedSaysWhereTheNextSketchGoes() {
        let one = SessionsMessage(sessions: [entry("a", folder: "acme-web")], target: "a")
        XCTAssertEqual(claude(.ownedAttached, sessions: one).subline, "Sketches go to acme-web")

        let two = SessionsMessage(sessions: [entry("a", folder: "acme-web"), entry("b", folder: "docs")], target: "b")
        let row = claude(.ownedAttached, sessions: two)
        XCTAssertEqual(row.word, "Connected")
        XCTAssertEqual(row.subline, "2 sessions \u{00B7} sketches go to docs")
    }

    func testSeveralSessionsAndNoTargetAsksForAPick() {
        let pick = SessionsMessage(sessions: [entry("a", folder: "acme-web"), entry("b", folder: "docs")], target: nil)
        let row = claude(.ownedAttached, sessions: pick)
        XCTAssertEqual(row.word, "Choose one")
        XCTAssertEqual(row.tint, .orange)
        XCTAssertEqual(row.subline, "Pick which session gets sketches")
    }

    func testAWaitingTargetSaysSoOnTheMacToo() {
        let waiting = SessionsMessage(sessions: [entry("a", folder: "acme-web", state: .waiting)], target: "a")
        XCTAssertEqual(claude(.ownedAttached, sessions: waiting).subline, "Claude Code is waiting for you in the Terminal")
    }

    func testANewSessionButtonWaitsForAProjectButKeepsItsSubline() {
        let one = SessionsMessage(sessions: [entry("a", folder: "acme-web")], target: "a")
        let row = claude(.ownedAttached, sessions: one, startBlocker: .noProject)
        XCTAssertEqual(row.action, .newSession)
        XCTAssertFalse(row.actionEnabled)
        XCTAssertEqual(row.subline, "Sketches go to acme-web")
    }

    func testSessionDetailTellsTwoSessionsInOneFolderApart() {
        let clock: (String) -> String? = { $0.hasPrefix("2026-10-05T10:00") ? "10:00" : "10:42" }
        XCTAssertEqual(
            MenuPresentation.sessionDetail(entry("a", folder: "acme", title: "fix header", branch: "main", lastReplyAt: "2026-10-05T10:42:00Z"), clock: clock),
            "fix header \u{00B7} main \u{00B7} replied 10:42"
        )
        XCTAssertEqual(
            MenuPresentation.sessionDetail(entry("b", folder: "acme", branch: "feat/nav"), clock: clock),
            "Started 10:00 \u{00B7} feat/nav", "no title: the start time stands in (X25)"
        )
        XCTAssertEqual(MenuPresentation.sessionDetail(entry("c", folder: "acme"), clock: { _ in nil }), "")
    }

    func testPendingSketchesBecomeTheSubline() {
        XCTAssertEqual(claude(.ownedAttached, pendingUploads: 1).subline, "1 sketch waiting to send")
        XCTAssertEqual(claude(.ownedAttached, pendingUploads: 3).subline, "3 sketches waiting to send")
    }

    func testExistingSessionPointsToDetails() {
        let row = claude(.existingSessionDetected)
        XCTAssertEqual(row.word, "Connected elsewhere")
        XCTAssertEqual(row.tint, .orange)
        XCTAssertEqual(row.subline, "Claude Code is connected to another copy of Design Canvas")
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

    func testWhereSketchesGoOutranksThePendingCount() {
        let one = SessionsMessage(sessions: [entry("a", folder: "acme-web")], target: "a")
        let row = claude(.ownedAttached, sessions: one, pendingUploads: 2)
        XCTAssertEqual(row.word, "Connected")
        XCTAssertEqual(row.subline, "Sketches go to acme-web")
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

    // The sender's status strings are sentences; the row keeps a short state word so the
    // device name is never the thing that truncates in a 320-point popover.

    func testFoundDeviceGetsAShortWordAndTheNextStepUnderneath() {
        let row = MenuPresentation.deviceRow(EngineDevice(
            id: "d1", name: "iPhone / iPad",
            status: "Device found \u{2014} open the OpenDisplay app on it\u{2026}", onUSB: true))
        XCTAssertEqual(row.word, "Found")
        XCTAssertEqual(row.subline, "Open Design Canvas on the iPad")
        XCTAssertEqual(row.action, .disconnect)
    }

    func testMirroringStatusDropsTheResolution() {
        let row = MenuPresentation.deviceRow(EngineDevice(
            id: "d1", name: "iPadz", status: "Mirroring to device (3024\u{00D7}1964)", onUSB: true))
        XCTAssertEqual(row.word, "Mirroring")
        XCTAssertNil(row.subline)
    }

    func testConnectedToEndpointDropsTheEndpointName() {
        let row = MenuPresentation.deviceRow(EngineDevice(
            id: "d1", name: "iPadz", status: "Connected to iPadz", onUSB: true))
        XCTAssertEqual(row.word, "Connected")
        XCTAssertNil(row.subline)
    }

    func testWaitingStatusesCollapseToWaiting() {
        for status in ["Waiting for receiver at iPadz\u{2026}", "Waiting for the device to connect\u{2026}"] {
            let row = MenuPresentation.deviceRow(EngineDevice(id: "d1", name: "iPadz", status: status, onUSB: true))
            XCTAssertEqual(row.word, "Waiting\u{2026}", status)
            XCTAssertNil(row.subline, status)
        }
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
