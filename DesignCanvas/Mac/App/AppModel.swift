// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/AppModel.swift`.
//
// Same shell: daemon supervision with the crash-loop guard, a 2 s health poll that re-verifies
// the daemon's identity (ADR-0004), the project picker and recents, `.mcp.json` ensure/update,
// Start / Disconnect / Reset, the 60 s launch timeout, and the session-state classifier.
//
// Changed for Design Canvas:
//   - health comes from `DaemonAPI.probe()` (Task 8's `DaemonClient`) instead of `HealthClient`;
//   - every capture path is gone (hotkey, HUD, frontmost tracker, window capturer, uploader) —
//     Design Canvas takes its frames from the engine's ring, not from a menu command;
//   - the app owns a `SenderEngine`, starts it at launch, mirrors its device list, and pushes
//     the project name and channel state into it so the iPad's status row is honest.

import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var sessionState: SessionState = SessionStateClassifier.classify(
        .init(probe: .refused, supervisedChildPid: nil, pinnedInstanceId: nil, sessionStarted: false, launchTimedOut: false)
    )
    /// Set by the picker, the recents list, or a test. The engine learns the folder name on every
    /// change — that name is what the iPad shows, and its absence is how "no project" is said.
    @Published var selectedProject: URL? {
        didSet { engine?.setProjectName(selectedProject?.lastPathComponent) }
    }
    @Published var sessionStarted = false
    @Published var configWarning: String?
    @Published var needsMcpUpdate = false
    @Published var serverEntry: String?
    @Published var screenRecordingGranted = ScreenRecordingPermission.isGranted
    @Published var daemonGaveUp = false
    @Published var lastResetOutcome: ResetOutcome?
    /// True for the whole span of `resetProcesses()` and, when it's the caller, the whole span of
    /// `startNewAfterReset()` (which calls `resetProcesses()` and then keeps polling/starts a
    /// session) — MenuBarView disables both reset buttons while true so a second tap can't
    /// overlap an in-flight reset.
    @Published var isResetting = false
    /// Mirror of `engine.devices`, republished whenever the engine reports a change. The menu
    /// reads this rather than the engine so the view stays a plain `@ObservedObject` consumer.
    @Published private(set) var devices: [EngineDevice] = []

    let nodePath: String

    private let recents = ProjectRecents()
    private let engine: SenderEngine?
    private var supervisor: DaemonSupervisor?
    private var pollTask: Task<Void, Never>?

    // MARK: - Poll/testability injection (ADR-0004: identity is re-verified every poll)
    private let probe: () async -> HealthProbeResult
    private let now: () -> Date
    /// Test-only override for the supervised child pid. Production code leaves this nil and
    /// reads `supervisor?.childPid` instead — faking `DaemonSupervisor`/`NodeProcessRunner` end
    /// to end isn't practical in unit tests, so this is the minimal seam tests need.
    private let testChildPidProvider: (() -> Int32?)?
    private let resetService: ProcessResetService
    /// Test-only override for the Terminal-launch effect inside `startSession()` — production
    /// defaults to the real `ClaudeLauncher.launchInTerminal`, which opens Terminal.app via
    /// AppleScript and is unsafe to invoke from a headless test run.
    private let launchInTerminal: (URL) -> String?
    /// Test-only override for the delay `startNewAfterReset()` waits between poll attempts —
    /// production waits ~2s for the daemon to come back up; tests inject a no-op so the bounded
    /// retry loop runs instantly.
    private let retryDelay: () async -> Void

    private var pinnedInstanceId: String?
    private var pinnedForPid: Int32?
    private var launchStartedAt: Date?
    private var launchTimedOutFlag = false
    /// The most recent raw probe outcome, kept for `resetProcesses()` to decide
    /// `refusedUnknownOccupant` without re-probing.
    private var lastProbeResult: HealthProbeResult = .refused
    /// Display of the previous poll; used only to detect the ownedAttached -> count 0 transition.
    private var previousDisplay: DisplayState = .noDaemon
    /// Depth counter backing `isResetting`: `startNewAfterReset()` calls `resetProcesses()`, and
    /// both use `beginResetting()`/`endResetting()`, so a plain Bool would get set back to false
    /// by the inner `resetProcesses()` call's own cleanup while the outer `startNewAfterReset()`
    /// is still running its post-reset poll loop. The counter keeps `isResetting` true until the
    /// outermost caller finishes.
    private var resettingDepth = 0

    private static let serverEntryKey = "serverEntryPath"
    private static let port = 47100
    private static let maxRestartPollAttempts = 10

    /// Production callers pass only the engine (`AppModel(engine: OpenDisplaySenderEngine())`).
    /// Passing a `probe` marks this a test construction: it skips the daemon supervisor and the
    /// 2 s poll timer so unit tests can drive `pollOnce()` deterministically without spawning
    /// real processes or touching AppleScript/Terminal. The engine is started either way — it is
    /// always a fake in tests, and it is the whole product in the app.
    init(
        probe: (() async -> HealthProbeResult)? = nil,
        now: @escaping () -> Date = Date.init,
        childPidProvider: (() -> Int32?)? = nil,
        resetService: ProcessResetService? = nil,
        launchInTerminal: ((URL) -> String?)? = nil,
        retryDelay: (() async -> Void)? = nil,
        engine: SenderEngine? = nil
    ) {
        nodePath = Self.resolveNodePath()
        self.now = now
        self.testChildPidProvider = childPidProvider
        self.resetService = resetService ?? ProcessResetService(query: PgrepProcessQuery(), signaling: PosixSignaler())
        self.launchInTerminal = launchInTerminal ?? ClaudeLauncher.launchInTerminal
        self.retryDelay = retryDelay ?? { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        self.engine = engine
        serverEntry = UserDefaults.standard.string(forKey: Self.serverEntryKey) ?? Self.defaultServerEntry()
        let daemon = DaemonClient(baseURL: URL(string: "http://127.0.0.1:\(Self.port)")!)
        self.probe = probe ?? { await daemon.probe() }

        devices = engine?.devices ?? []
        engine?.onDevicesChanged = { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.devices = engine.devices
        }
        engine?.start()

        guard probe == nil else { return }
        // Restore the most recent project so a relaunch doesn't start from a blank menu.
        if let last = recents.all.first, FileManager.default.fileExists(atPath: last.path) {
            selectRecent(last)
        }
        restartSupervisor()
        startHealthPolling()
    }

    // MARK: - Recents

    var recentProjects: [URL] { recents.all }

    // MARK: - Node resolution

    private static func resolveNodePath() -> String {
        if let viaShell = nodePathFromLoginShell(), !viaShell.isEmpty {
            return viaShell
        }
        let fallbacks = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        for candidate in fallbacks where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return "node"
    }

    private static func nodePathFromLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which node"]
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
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Server build

    /// Where a locally built server lives, relative to a checkout.
    private static let serverEntryRelativePath = "DesignCanvas/server/dist/index.js"

    /// First guess at the server build, used only when the user has never chosen one. Pure so it
    /// can be tested without touching the filesystem. The selected project is deliberately never
    /// one of the roots: a user's repo is not where this app's own server build lives.
    static func defaultServerEntry(roots: [URL], fileExists: (String) -> Bool) -> String? {
        for root in roots {
            let candidate = root.appendingPathComponent(serverEntryRelativePath).path
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    /// The two roots a locally built app actually runs from: the working directory (launched
    /// from a terminal inside the checkout) and the folder holding the `.app`. Nothing found
    /// leaves `serverEntry` nil and the menu shows "Set server build…".
    private static func defaultServerEntry() -> String? {
        defaultServerEntry(
            roots: [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                Bundle.main.bundleURL.deletingLastPathComponent(),
            ],
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    // MARK: - Daemon supervision

    private func restartSupervisor() {
        supervisor?.stop()
        supervisor = nil
        daemonGaveUp = false
        guard let serverEntry, FileManager.default.fileExists(atPath: serverEntry) else { return }
        let runner = NodeProcessRunner(nodePath: nodePath, serverEntry: serverEntry, port: Self.port)
        let supervisor = DaemonSupervisor(runner: runner)
        supervisor.onGiveUp = { [weak self] in self?.daemonGaveUp = true }
        supervisor.start()
        self.supervisor = supervisor
    }

    private func currentChildPid() -> Int32? {
        if let testChildPidProvider { return testChildPidProvider() }
        return supervisor?.childPid
    }

    // MARK: - Health polling

    private func startHealthPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// One poll cycle: probe, re-verify pinned identity, update the launch-timeout clock,
    /// classify, publish, and hand the engine the channel state the iPad needs. The timer loop
    /// above calls this every 2s; tests call it directly.
    func pollOnce() async {
        let result = await probe()
        lastProbeResult = result
        let childPid = currentChildPid()

        // Pin (child pid, instanceId) the first time we see our own child's pid; re-pins
        // automatically whenever the supervisor hands us a different child pid.
        if case .healthy(let h) = result, let pid = h.pid, let childPid, pid == Int(childPid) {
            if pinnedForPid != childPid {
                pinnedForPid = childPid
                pinnedInstanceId = h.instanceId
            }
        }
        let effectivePinnedInstanceId = (pinnedForPid == childPid) ? pinnedInstanceId : nil
        let count = SessionStateClassifier.channelCount(result)

        // Our owned+attached session's channel dropped back to 0 -> the user quit Claude Code.
        // End the session without a button. Gated on an AUTHORITATIVE zero (`result` healthy) —
        // `channelCount()` also returns 0 for a non-healthy probe (.timedOut/.refused/etc.), and
        // a single transient stall (the probe times out at 1.5s) must never be read as "the
        // channel dropped to 0"; that would orphan a live session over one missed poll.
        if case .healthy = result, previousDisplay == .ownedAttached, count == 0 {
            sessionStarted = false
        }

        // Launch clock: stamps on the sessionStarted false -> true edge. `startSession()` also
        // stamps immediately for the real Start-button path; this catches the edge in general
        // (and is what test-driven `sessionStarted` flips rely on). Cleared whenever not started.
        if sessionStarted {
            if launchStartedAt == nil { launchStartedAt = now() }
        } else {
            launchStartedAt = nil
        }

        if count > 0 {
            launchTimedOutFlag = false
        } else if sessionStarted, let launchStartedAt {
            launchTimedOutFlag = now().timeIntervalSince(launchStartedAt) > 60
        } else {
            launchTimedOutFlag = false
        }

        let input = SessionStateClassifier.Input(
            probe: result,
            supervisedChildPid: childPid,
            pinnedInstanceId: effectivePinnedInstanceId,
            sessionStarted: sessionStarted,
            launchTimedOut: launchTimedOutFlag
        )
        let newState = SessionStateClassifier.classify(input)
        sessionState = newState
        previousDisplay = newState.display

        // The iPad's channel row is whatever this poll saw. `ChannelState(probe:)` collapses
        // every unreachable/foreign outcome to `.none`, which is the honest answer: an app that
        // can't see the daemon can't claim a channel is attached.
        engine?.setChannelState(ChannelState(probe: result))

        // Cheap, non-prompting TCC query — so the permission row goes green on the next tick
        // after the user grants it, instead of staying stale until relaunch.
        screenRecordingGranted = ScreenRecordingPermission.isGranted
    }

    // MARK: - Project selection

    func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            configWarning = nil
            needsMcpUpdate = false
            selectedProject = url
            recents.add(url)
        }
    }

    func selectRecent(_ url: URL) {
        configWarning = nil
        needsMcpUpdate = false
        selectedProject = url
    }

    // MARK: - Server build selection

    func setServerBuild() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            UserDefaults.standard.set(path, forKey: Self.serverEntryKey)
            serverEntry = path
            restartSupervisor()
        }
    }

    // MARK: - Session lifecycle

    /// Start-button gate. `sessionState.canStart` only refreshes on the 2s poll, so on its own it
    /// leaves a window where a fast double-click launches two sessions. `sessionStarted` is set
    /// synchronously inside `startSession()`, so OR-ing it in re-disables the button immediately.
    var startDisabled: Bool { sessionStarted || !sessionState.canStart }

    func startSession() {
        guard !sessionStarted else { return } // defense in depth: startDisabled already gates the button
        guard let project = selectedProject, let serverEntry else { return }
        let result: EnsureResult
        do {
            result = try McpConfigManager().ensureEntry(
                repoRoot: project,
                command: nodePath,
                args: [serverEntry, "--channel"]
            )
        } catch {
            configWarning = "Couldn't read .mcp.json: \(error)"
            return
        }
        if case .needsUpdate = result {
            // The project has a non-channel 'design-canvas' entry (e.g. a stale --mcp from
            // before the rename). Don't launch; offer an explicit fix via updateMcpEntry().
            configWarning = nil
            needsMcpUpdate = true
            return
        }
        // .created or .alreadyCompatible — an existing --channel entry is used as-is.
        needsMcpUpdate = false
        if let launchError = launchInTerminal(project) {
            // Terminal didn't open (e.g. Automation permission denied) — don't claim a session.
            configWarning = launchError
            sessionStarted = false
            return
        }
        configWarning = nil
        sessionStarted = true
        launchStartedAt = now()
        launchTimedOutFlag = false
    }

    /// User opted to fix a stale 'design-canvas' entry: overwrite it with a valid --channel
    /// entry (preserving other servers), then launch.
    func updateMcpEntry() {
        guard let project = selectedProject, let serverEntry else { return }
        do {
            try McpConfigManager().updateEntry(repoRoot: project, command: nodePath, args: [serverEntry, "--channel"])
        } catch {
            configWarning = "Couldn't update .mcp.json: \(error)"
            return
        }
        needsMcpUpdate = false
        startSession()
    }

    /// App-side only: stop tracking the launched session and re-enable Start. Does NOT quit
    /// Claude Code (spec section 6) — the user ends it by quitting it in its Terminal. The
    /// session also auto-resets when the channel detaches (see the health poll above).
    func disconnect() {
        configWarning = nil
        needsMcpUpdate = false
        sessionStarted = false
        launchStartedAt = nil
        launchTimedOutFlag = false
    }

    // MARK: - Reset

    private func beginResetting() {
        resettingDepth += 1
        isResetting = true
    }

    private func endResetting() {
        resettingDepth = max(0, resettingDepth - 1)
        if resettingDepth == 0 {
            isResetting = false
        }
    }

    /// Stops the app's own supervised daemon (via the supervisor, never a direct signal), sweeps
    /// up any argv-verified design-canvas helper processes still on the port, restarts the
    /// daemon, and immediately re-probes so the menu reflects the new state without waiting for
    /// the next 2s tick. Never touches Claude Code — see `ProcessResetService`'s kill gate. No-op
    /// when no server build is set: there is nothing to sweep or restart.
    func resetProcesses() async {
        guard let serverEntry else { return }
        // Clear any outcome from a previous run up front — a stale "some processes didn't stop"
        // line must not linger on screen for the span of this new attempt; it's superseded below
        // once this attempt's own outcome is known.
        lastResetOutcome = nil
        beginResetting()
        defer { endResetting() }
        // Capture the child pid BEFORE stopping the supervisor — `DaemonSupervisor.stop()` clears
        // `childPid`, and the reset service needs it to exclude the app's own child from the kill
        // list.
        let ownChildPid = currentChildPid()
        supervisor?.stop()
        supervisor = nil
        // `reset()` blocks (grace-period sleeps between isAlive checks, up to ~1s per surviving
        // pid), so hop it off the main actor — a detached task keeps the menu UI responsive.
        // All inputs are captured as immutable locals BEFORE the hop; no @MainActor state is
        // touched inside the detached closure.
        let service = resetService
        let lastProbe = lastProbeResult
        let outcome = await Task.detached {
            service.reset(serverEntry: serverEntry, lastProbe: lastProbe, ownChildPid: ownChildPid)
        }.value
        lastResetOutcome = outcome
        restartSupervisor()
        await pollOnce()
    }

    /// Runs `resetProcesses()`, then polls (bounded, ~10 attempts) until the daemon comes back up
    /// owned and channel-free, then starts a session the same way the Start button does. If the
    /// bound is exceeded, surfaces a failure via `configWarning` (the same row the menu already
    /// renders for other startSession() failures) instead of silently doing nothing.
    func startNewAfterReset() async {
        guard serverEntry != nil else { return }
        beginResetting()
        defer { endResetting() }
        await resetProcesses()
        var attempts = 0
        while !sessionState.canStart, attempts < Self.maxRestartPollAttempts {
            if sessionStarted {
                // The user clicked Start manually mid-retry (e.g. the background 2s poll loop
                // showed canStart briefly, independent of this retry loop's own polls) — a
                // session is already starting. Don't fight it, and don't let the loop keep
                // spinning toward a stale "reset didn't reach a startable state" warning below.
                return
            }
            await retryDelay()
            await pollOnce()
            attempts += 1
        }
        if sessionState.canStart {
            startSession()
        } else if !sessionStarted {
            configWarning = "Reset didn't reach a startable state in time \u{2014} try Start manually once the daemon is back up."
        }
    }

    // MARK: - Permissions

    /// Registers the app in the Screen Recording list (CGRequestScreenCaptureAccess prompts +
    /// registers it) and, if that didn't grant it, opens the Privacy pane so the user can enable
    /// it. A freshly-granted permission needs an app relaunch to take effect.
    func openScreenRecordingSettings() {
        screenRecordingGranted = ScreenRecordingPermission.request()
        if !screenRecordingGranted {
            ScreenRecordingPermission.openSystemSettings()
        }
    }

    func quit() {
        pollTask?.cancel()
        engine?.stop()
        supervisor?.stop()
        NSApplication.shared.terminate(nil)
    }

    deinit {
        pollTask?.cancel()
    }
}
