// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/AppModel.swift`.
//
// Same shell: daemon supervision with the crash-loop guard, a 2 s health poll that re-verifies
// the daemon's identity (ADR-0004), the project picker and recents, Start / Reset, the 60 s
// launch timeout, and the session-state classifier.
//
// Changed for Design Canvas:
//   - health comes from `DaemonAPI.probe()` (Task 8's `DaemonClient`) instead of `HealthClient`;
//   - every capture path is gone (hotkey, HUD, frontmost tracker, window capturer, uploader) —
//     Design Canvas takes its frames from the engine's ring, not from a menu command;
//   - the app owns a `SenderEngine`, starts it at launch, mirrors its device list, and pushes
//     the project name and channel state into it so the iPad's status row is honest;
//   - Claude Code is reached through the Design Canvas mod, not a channel
//     (`spec/technical_doc-ClaudeMods.md`): Start launches it with the mod bundled in this
//     app and writes nothing into the project, any session with the mod loaded is usable
//     whoever started it, and the app lists the connected sessions and which one gets sketches.

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
    /// A launch from Start is on its way: set on the click, cleared when the session it started
    /// registers (or the launch is given up on). Not "a session is connected": sessions are
    /// usable whoever started them, and the daemon's list says which are there.
    @Published var sessionStarted = false
    @Published var configWarning: String?
    /// The connected Claude Code sessions and the target, as of the last poll (X21 to X26).
    @Published private(set) var sessions: DaemonSessions = .empty
    /// "Use Design Canvas in every Claude Code session" (X20). Mirrors what is in the user's
    /// Claude Code settings, which is the only place the choice has any effect.
    @Published private(set) var everySessionEnabled = false
    /// Why the last change to that option did not take, in the user's words.
    @Published var everySessionError: String?
    /// The mod this app starts sessions with; nil when the build has none (a Debug build made
    /// outside a checkout), in which case Start says so.
    let modDirectory: String?
    @Published var serverEntry: String?
    /// Screen Recording as the menu shows it: the preflight, or a running capture, whichever
    /// says yes (see `pollOnce`). Set from the probe in `init`.
    @Published var screenRecordingGranted = false
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
    /// Mirror of `engine.discovered`: devices the sender can see but is not serving. The menu
    /// offers each one a Connect, which is the only way a WiFi iPad can be started at all —
    /// `SenderController` auto-connects a WiFi device only once the user has connected to it
    /// once (I1, PRD D1).
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    /// Sketches the engine has accepted and not yet delivered to the daemon, refreshed on every
    /// health poll. Nothing reported this before, so a daemon that was down looked like a sketch
    /// that had vanished (I3).
    @Published private(set) var pendingUploads = 0

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
    private let launchInTerminal: (ClaudeLaunch) -> String?
    /// The daemon's session list; nil when it could not be read.
    private let sessionsFetch: () async -> DaemonSessions?
    private let targetSetter: (String) async -> Void
    /// What `claude --version` prints, or nil when `claude` cannot be run.
    private let claudeVersionOutput: () -> String?
    /// Checked once in the background at launch so Start does not wait on a shell; re-checked
    /// on Start only while the last answer was a refusal, since the user may have just fixed it.
    private var claudeAvailability: ClaudeAvailability?
    private let claudeSettings: ClaudeSettingsManager
    private let defaults: UserDefaults
    /// Test-only override for the delay `startNewAfterReset()` waits between poll attempts —
    /// production waits ~2s for the daemon to come back up; tests inject a no-op so the bounded
    /// retry loop runs instantly.
    private let retryDelay: () async -> Void
    /// The Screen Recording preflight — `CGPreflightScreenCaptureAccess()` in production, a
    /// flag in tests. Never the only word: `pollOnce` lets a capturing engine overrule it.
    private let screenRecordingProbe: () -> Bool
    /// The preflight disagreeing with a running capture is logged once per run, with a reading
    /// from off the main thread, so the log says which of the two the OS quirk depends on.
    private var preflightDisagreementLogged = false

    private var pinnedInstanceId: String?
    private var pinnedForPid: Int32?
    private var launchStartedAt: Date?
    private var launchTimedOutFlag = false
    /// The nonce of the launch in flight (and, persisted, of the last one), which is how the
    /// session it started is recognised in the daemon's list.
    private var launchNonce: String?
    /// The most recent raw probe outcome, kept for `resetProcesses()` to decide
    /// `refusedUnknownOccupant` without re-probing, and shown raw in the Details window.
    private(set) var lastProbeResult: HealthProbeResult = .refused
    /// Depth counter backing `isResetting`: `startNewAfterReset()` calls `resetProcesses()`, and
    /// both use `beginResetting()`/`endResetting()`, so a plain Bool would get set back to false
    /// by the inner `resetProcesses()` call's own cleanup while the outer `startNewAfterReset()`
    /// is still running its post-reset poll loop. The counter keeps `isResetting` true until the
    /// outermost caller finishes.
    private var resettingDepth = 0

    private static let serverEntryKey = "serverEntryPath"
    private static let launchNonceKey = "launchNonce"
    static let everySessionAskedKey = "everySessionAsked"
    /// The mod directory this app last wrote into the user's Claude Code settings, kept so a
    /// moved app can take its old path out again.
    static let registeredModDirectoryKey = "registeredModDirectory"
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
        launchInTerminal: ((ClaudeLaunch) -> String?)? = nil,
        retryDelay: (() async -> Void)? = nil,
        engine: SenderEngine? = nil,
        screenRecordingProbe: (() -> Bool)? = nil,
        sessionsFetch: (() async -> DaemonSessions?)? = nil,
        targetSetter: ((String) async -> Void)? = nil,
        claudeVersionOutput: (() -> String?)? = nil,
        modDirectory: String? = nil,
        claudeSettings: ClaudeSettingsManager? = nil,
        defaults: UserDefaults = .standard
    ) {
        nodePath = Self.resolveNodePath()
        self.now = now
        self.testChildPidProvider = childPidProvider
        self.resetService = resetService ?? ProcessResetService(query: PgrepProcessQuery(), signaling: PosixSignaler())
        self.launchInTerminal = launchInTerminal ?? ClaudeLauncher.launchInTerminal
        self.retryDelay = retryDelay ?? { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        self.engine = engine
        let probeScreenRecording = screenRecordingProbe ?? { ScreenRecordingPermission.isGranted }
        self.screenRecordingProbe = probeScreenRecording
        screenRecordingGranted = probeScreenRecording()
        serverEntry = UserDefaults.standard.string(forKey: Self.serverEntryKey) ?? Self.defaultServerEntry()
        let daemon = DaemonClient(baseURL: URL(string: "http://127.0.0.1:\(Self.port)")!)
        self.probe = probe ?? { await daemon.probe() }
        let isTest = probe != nil
        // A test construction has no daemon to ask and no shell to run `claude` in: it sees no
        // sessions and a Claude Code that is new enough, unless it injects otherwise.
        self.sessionsFetch = sessionsFetch ?? (isTest ? { nil } : { try? await daemon.sessions() })
        self.targetSetter = targetSetter ?? (isTest ? { _ in } : { instance in
            try? await daemon.setTarget(instance: instance, fromIPad: false)
        })
        self.claudeVersionOutput = claudeVersionOutput
            ?? (isTest ? { "\(ClaudeVersion.minimumForMods) (Claude Code)" } : ClaudeLauncher.versionOutputFromLoginShell)
        self.modDirectory = modDirectory ?? (isTest ? "/test/Design Canvas.app/Contents/Resources/mod" : Self.defaultModDirectory())
        self.claudeSettings = claudeSettings ?? ClaudeSettingsManager()
        self.defaults = defaults
        launchNonce = defaults.string(forKey: Self.launchNonceKey)

        devices = engine?.devices ?? []
        discoveredDevices = engine?.discovered ?? []
        engine?.onDevicesChanged = { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.devices = engine.devices
            self.discoveredDevices = engine.discovered
        }
        engine?.start()

        guard probe == nil else { return }
        refreshEverySession()
        checkClaudeInBackground()
        // After the scene is up: a menu-bar app has no window to hang the question on.
        DispatchQueue.main.async { [weak self] in self?.askAboutEverySessionIfNeeded() }
        // Restore the most recent project so a relaunch doesn't start from a blank menu.
        if let last = recents.all.first, FileManager.default.fileExists(atPath: last.path) {
            selectRecent(last)
        }
        restartSupervisor()
        startHealthPolling()
    }

    // MARK: - Devices

    /// Dial a discovered device (a menu tap). A WiFi device connected this way is remembered by
    /// the sender, so later launches auto-reconnect it.
    func connectDevice(id: String) {
        engine?.connect(id: id)
    }

    /// Stop serving a connected device, and stop auto-connecting it.
    func disconnectDevice(id: String) {
        engine?.disconnect(id: id)
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

    /// Where the server lives inside the app (`tools/bundle-server.sh`, run at build time),
    /// relative to `Contents/Resources`.
    private static let bundledServerEntryRelativePath = "server/dist/index.js"
    /// Where a locally built server lives, relative to a checkout.
    private static let serverEntryRelativePath = "DesignCanvas/server/dist/index.js"

    /// First guess at the server build, used only when the user has never chosen one. Pure so it
    /// can be tested without touching the filesystem. The copy bundled with the app wins; the
    /// checkout roots are the fallback for a Debug build made without pnpm. The selected project
    /// is deliberately never one of the roots: a user's repo is not where this app's own server
    /// build lives.
    static func defaultServerEntry(resources: URL?, roots: [URL], fileExists: (String) -> Bool) -> String? {
        var candidates = roots.map { $0.appendingPathComponent(serverEntryRelativePath).path }
        if let resources {
            candidates.insert(resources.appendingPathComponent(bundledServerEntryRelativePath).path, at: 0)
        }
        return candidates.first(where: fileExists)
    }

    /// The bundle's Resources, then the two roots a locally built app actually runs from: the
    /// working directory (launched from a terminal inside the checkout) and the folder holding
    /// the `.app`. Nothing found leaves `serverEntry` nil and Settings offers the picker.
    private static func defaultServerEntry() -> String? {
        defaultServerEntry(
            resources: Bundle.main.resourceURL,
            roots: [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                Bundle.main.bundleURL.deletingLastPathComponent(),
            ],
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    // MARK: - The mod

    /// Where the mod lives inside the app (copied there at build time by `tools/bundle-mod.sh`),
    /// relative to `Contents/Resources`, and in a checkout.
    private static let bundledModRelativePath = "mod"
    private static let checkoutModRelativePath = "DesignCanvas/mod"
    private static let modEntryRelativePath = "hooks/register.js"

    /// The mod directory to start sessions with. Pure, like `defaultServerEntry`: the copy inside
    /// the app wins, a checkout is the fallback for a Debug build run from one.
    static func defaultModDirectory(resources: URL?, roots: [URL], fileExists: (String) -> Bool) -> String? {
        var candidates = roots.map { $0.appendingPathComponent(checkoutModRelativePath) }
        if let resources {
            candidates.insert(resources.appendingPathComponent(bundledModRelativePath), at: 0)
        }
        return candidates.first { fileExists($0.appendingPathComponent(modEntryRelativePath).path) }?.path
    }

    private static func defaultModDirectory() -> String? {
        defaultModDirectory(
            resources: Bundle.main.resourceURL,
            roots: [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                Bundle.main.bundleURL.deletingLastPathComponent(),
            ],
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    // MARK: - Every session (X20)

    /// True until the first-launch question has been answered once, either way.
    var shouldAskAboutEverySession: Bool {
        modDirectory != nil && !defaults.bool(forKey: Self.everySessionAskedKey)
    }

    /// The first-launch question (X20): asked once, with what yes means spelled out, and "Not
    /// Now" as the default so a reflexive Return turns nothing on. (Manual-verified.)
    private func askAboutEverySessionIfNeeded() {
        guard shouldAskAboutEverySession else { return }
        let alert = NSAlert()
        alert.messageText = "Use Design Canvas in every Claude Code session?"
        alert.informativeText = """
        If you turn this on, the Design Canvas plugin loads in every Claude Code session you start, in every project, and starting a session opens this app if it isn't running. You can then just run claude in a project and sketch.

        If you leave it off, use Start in the Design Canvas menu to open a session. You can change this any time in Settings.
        """
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Turn On")
        NSApp.activate(ignoringOtherApps: true)
        answerEverySessionQuestion(alert.runModal() == .alertSecondButtonReturn)
    }

    /// Records the answer to the first-launch question and applies it.
    func answerEverySessionQuestion(_ yes: Bool) {
        defaults.set(true, forKey: Self.everySessionAskedKey)
        if yes { setEverySession(true) }
    }

    /// Turns the option on or off by listing or unlisting this app's mod in the user's Claude
    /// Code settings. Off removes exactly what on added. A settings file that does not parse
    /// is left alone and the option stays as it was, with the reason shown.
    func setEverySession(_ enabled: Bool) {
        everySessionError = nil
        do {
            if enabled {
                guard let modDirectory else {
                    everySessionError = "This build has no Design Canvas mod to turn on."
                    return
                }
                try claudeSettings.add(modDirectory, replacing: defaults.string(forKey: Self.registeredModDirectoryKey))
                defaults.set(modDirectory, forKey: Self.registeredModDirectoryKey)
            } else {
                for directory in Set([modDirectory, defaults.string(forKey: Self.registeredModDirectoryKey)].compactMap { $0 }) {
                    try claudeSettings.remove(directory)
                }
                defaults.removeObject(forKey: Self.registeredModDirectoryKey)
            }
        } catch {
            everySessionError = "Couldn't change \(claudeSettings.settingsURL.path): it is not valid JSON. Fix or remove the file, then try again."
        }
        everySessionEnabled = currentEverySession()
    }

    private func currentEverySession() -> Bool {
        let registered = defaults.string(forKey: Self.registeredModDirectoryKey)
        return [modDirectory, registered].compactMap { $0 }.contains { claudeSettings.contains($0) }
    }

    /// At launch: read the option back from the settings file, and if it is on but points at
    /// where this app used to be, point it at where the app is now (XG7's self-repair).
    func refreshEverySession() {
        let registered = defaults.string(forKey: Self.registeredModDirectoryKey)
        if let modDirectory, let registered, registered != modDirectory, claudeSettings.contains(registered) {
            setEverySession(true)
            return
        }
        everySessionEnabled = currentEverySession()
    }

    // MARK: - Claude Code version (X10)

    private func checkClaudeInBackground() {
        let read = claudeVersionOutput
        Task { [weak self] in
            // A shell start, so off the main actor; the answer comes back onto it.
            let availability = await Task.detached { ClaudeAvailability(versionOutput: read()) }.value
            self?.claudeAvailability = availability
        }
    }

    /// The reason Start cannot go ahead, or nil. A cached "ok" is trusted; anything else is
    /// read again, because the usual way out of a refusal is the user installing or updating
    /// Claude Code and clicking Start once more.
    private func claudeBlockingMessage() -> String? {
        if case .ok = claudeAvailability { return nil }
        let availability = ClaudeAvailability(versionOutput: claudeVersionOutput())
        claudeAvailability = availability
        return availability.blockingMessage
    }

    // MARK: - Sessions (X21 to X26)

    /// Makes one connected session the target for the next sketch (a menu click).
    func selectTarget(_ instance: String) {
        Task {
            await targetSetter(instance)
            if let latest = await sessionsFetch() { sessions = latest }
        }
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
        let count = SessionStateClassifier.sessionCount(result)

        // The list behind the count: who is connected, and which one gets sketches. A daemon
        // that is not ours or not there has no list worth showing.
        let fetched: DaemonSessions? = { if case .healthy = result { return true } else { return false } }()
            ? await sessionsFetch() : nil
        let latest = fetched ?? .empty
        if latest != sessions { sessions = latest }

        // A launch from Start has arrived when the session carrying its nonce is in the list.
        // With no list to read, any connected session ends the wait: it is there to be used.
        if sessionStarted {
            let arrived = fetched.map { list in list.sessions.contains { $0.launch != nil && $0.launch == launchNonce } }
                ?? (count > 0)
            if arrived { sessionStarted = false }
        }

        // Launch clock: stamps on the sessionStarted false -> true edge. `startSession()` also
        // stamps immediately for the real Start-button path; this catches the edge in general
        // (and is what test-driven `sessionStarted` flips rely on). Cleared whenever not started.
        if sessionStarted {
            if launchStartedAt == nil { launchStartedAt = now() }
        } else {
            launchStartedAt = nil
        }

        if sessionStarted, let launchStartedAt {
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

        // The iPad's dot hears the same verdict the menu shows (D7), so the two can't disagree.
        engine?.setChannelState(ChannelState(session: newState))

        // The engine has no change notification for this — it moves on its own upload queue's
        // schedule — so the 2 s poll is what refreshes the menu's "waiting for the daemon" row.
        let stillPending = engine?.pendingUploads ?? 0
        if stillPending != pendingUploads { pendingUploads = stillPending }

        // Cheap, non-prompting TCC query — so the permission row goes green on the next tick
        // after the user grants it, instead of staying stale until relaunch. A running capture
        // outranks it: on macOS 26 (2026-09-30) the preflight answered no on this poll while the
        // same process was mirroring to the iPad, and the row must never contradict the screen.
        let preflight = screenRecordingProbe()
        let capturing = engine?.isCapturing ?? false
        let granted = preflight || capturing
        if granted != screenRecordingGranted {
            Log.info("Screen Recording: \(granted ? "granted" : "not granted") (preflight \(preflight), capturing \(capturing))")
        }
        if capturing, !preflight, !preflightDisagreementLogged {
            preflightDisagreementLogged = true
            Task.detached {
                let offMain = ScreenRecordingPermission.isGranted
                Log.info("Screen Recording: preflight says no while frames are flowing (main actor false, background thread \(offMain))")
            }
        }
        screenRecordingGranted = granted
    }

    // MARK: - Project selection

    func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder Claude Code should work in."
        // A menu-bar app is never the active app on its own. Without this the panel opens
        // unfocused and behind whatever is in front, where it can look like it won't take a
        // selection (seen 2026-10-06).
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            configWarning = nil
            selectedProject = url
            recents.add(url)
        }
    }

    func selectRecent(_ url: URL) {
        configWarning = nil
        selectedProject = url
    }

    // MARK: - Server build selection

    func setServerBuild() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
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

    /// Launches Claude Code in the selected project with the mod bundled in this app (X1).
    /// Nothing is written into the project (X2): no `.mcp.json` entry is created, and one left
    /// by an earlier version is neither read nor changed.
    func startSession() {
        guard !sessionStarted else { return } // defense in depth: startDisabled already gates the button
        guard let project = selectedProject else { return }
        guard let modDirectory else {
            configWarning = "This build of Design Canvas has no Claude Code mod inside it. Rebuild the app, or run it from a checkout."
            return
        }
        if let blocked = claudeBlockingMessage() {
            // X10: say what is wrong and what to do, and do not open a Terminal that would
            // only show an error.
            configWarning = blocked
            return
        }
        let nonce = UUID().uuidString
        if let launchError = launchInTerminal(ClaudeLaunch(repoRoot: project, modDirectory: modDirectory, nonce: nonce)) {
            // Terminal didn't open (e.g. Automation permission denied) — don't claim a launch.
            configWarning = launchError
            sessionStarted = false
            return
        }
        launchNonce = nonce
        defaults.set(nonce, forKey: Self.launchNonceKey)
        configWarning = nil
        sessionStarted = true
        launchStartedAt = now()
        launchTimedOutFlag = false
    }

    /// App-side only: give up waiting for a launch and re-enable Start. Does NOT quit Claude
    /// Code (spec section 6) — the user ends a session by quitting it in its Terminal — and has
    /// no effect on connected sessions, which stay listed for as long as they run.
    func disconnect() {
        configWarning = nil
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
        let requested = ScreenRecordingPermission.request()
        Log.info("Screen Recording: request returned \(requested)")
        screenRecordingGranted = requested || (engine?.isCapturing ?? false)
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
