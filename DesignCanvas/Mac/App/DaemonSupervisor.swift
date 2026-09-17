// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/DaemonSupervisor.swift`.
//
// The supervisor itself is unchanged: restart on exit, with the crash-loop guard at 1.0 s
// restart delay / 2.0 s fast-exit threshold / 3 consecutive strikes.

import Foundation

@MainActor
protocol ProcessRunning {
    /// pid of the running child; nil once it has stopped or exited.
    var pid: Int32? { get }
    /// Starts the process. `onExit` is always delivered on the main queue.
    func start(onExit: @escaping (Int32) -> Void)
    func stop()
}

enum DaemonState { case stopped, running, gaveUp }

@MainActor
final class DaemonSupervisor {
    enum Intent { case stopped, running }
    private let runner: ProcessRunning
    private let restartDelay: TimeInterval
    private let fastExitThreshold: TimeInterval
    private let maxConsecutiveFastExits: Int
    private let now: () -> Date
    private(set) var state: DaemonState = .stopped
    private(set) var childPid: Int32?
    var onGiveUp: (() -> Void)?
    private var intent: Intent = .stopped
    private var consecutiveFastExits = 0
    private var runStartedAt: Date?

    init(
        runner: ProcessRunning,
        restartDelay: TimeInterval = 1.0,
        fastExitThreshold: TimeInterval = 2.0,
        maxConsecutiveFastExits: Int = 3,
        now: @escaping () -> Date = Date.init
    ) {
        self.runner = runner
        self.restartDelay = restartDelay
        self.fastExitThreshold = fastExitThreshold
        self.maxConsecutiveFastExits = maxConsecutiveFastExits
        self.now = now
    }

    /// Starts the daemon. Also used to explicitly retry after `.gaveUp`, which
    /// clears the consecutive-fast-exit counter.
    func start() {
        intent = .running
        consecutiveFastExits = 0
        launch()
    }

    private func launch() {
        runStartedAt = now()
        runner.start { [weak self] _ in
            guard let self, self.intent == .running else { return }
            self.childPid = nil
            let elapsed = self.now().timeIntervalSince(self.runStartedAt ?? self.now())
            if elapsed < self.fastExitThreshold {
                self.consecutiveFastExits += 1
            } else {
                self.consecutiveFastExits = 0
            }
            if self.consecutiveFastExits >= self.maxConsecutiveFastExits {
                self.intent = .stopped
                self.state = .gaveUp
                self.onGiveUp?()
                return
            }
            if self.restartDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.restartDelay) { [weak self] in
                    guard let self, self.intent == .running else { return }
                    self.launch()
                }
            } else {
                self.launch()
            }
        }
        state = .running
        childPid = runner.pid
    }

    func stop() {
        intent = .stopped
        runner.stop()
        state = .stopped
        childPid = nil
    }
}

/// The environment the daemon child is spawned with.
///
/// ai.cst.2 set `SERVER_HOST=0.0.0.0` here so the iPad could reach the daemon over the LAN.
/// Design Canvas carries the annotation on the OpenDisplay connection instead, so the daemon
/// binds `127.0.0.1` and ignores `SERVER_HOST` entirely. Stripping an inherited value is belt
/// and braces on top of that: it makes "nothing this app launches can be told to listen on the
/// LAN" a property of the launcher, testable without a daemon.
enum DaemonEnvironment {
    static func make(base: [String: String], port: Int) -> [String: String] {
        var env = base
        env["SERVER_PORT"] = String(port)
        env.removeValue(forKey: "SERVER_HOST")
        return env
    }
}

/// Production runner: spawns `node <serverEntry> --http`. Manual-verified.
@MainActor
final class NodeProcessRunner: ProcessRunning {
    private let nodePath: String
    private let serverEntry: String
    private let port: Int
    private var process: Process?

    var pid: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    init(nodePath: String, serverEntry: String, port: Int = 47100) {
        self.nodePath = nodePath
        self.serverEntry = serverEntry
        self.port = port
    }

    func start(onExit: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: nodePath)
        p.arguments = [serverEntry, "--http"]
        p.environment = DaemonEnvironment.make(base: ProcessInfo.processInfo.environment, port: port)
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.process = nil
                    onExit(status)
                }
            }
        }
        try? p.run()
        process = p
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }
}
