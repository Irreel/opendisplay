// Ported from ai.cst.2 `apps/desktop/DesignCanvasDesktop/ProcessResetService.swift`.
// Only change: `Health` is now `DaemonHealth` (Task 8), reached through `HealthProbeResult`.
// The kill gate is unchanged, and it is what makes requirement 5 true — Reset never kills
// Claude Code.

import Darwin
import Foundation

/// A process found by `ProcessQuerying`, before argv verification is applied by
/// `ProcessResetService`. `command` is the full command line (`ps -o command=`), not just the
/// executable name, because verification depends on the *full* `serverEntry` path appearing in it.
struct ProcessCandidate: Equatable {
    let pid: Int32
    let command: String
}

/// Finds OS processes that might be design-canvas helpers. Implementations only look up
/// candidates — they must NOT decide who is safe to kill; `ProcessResetService` owns that
/// decision so the safety rules live in one auditable place.
protocol ProcessQuerying {
    func candidates(matching serverEntry: String) throws -> [ProcessCandidate]
}

/// Sends signals to a pid. `terminate` is SIGTERM only — there is no SIGKILL method on this
/// protocol by construction (absolute safety rule: SIGTERM only, never escalate).
protocol ProcessSignaling {
    /// Sends SIGTERM. Returns `false` if the signal could not be delivered (e.g. EPERM).
    /// An already-dead target (ESRCH) counts as success — the goal of terminate is achieved.
    func terminate(pid: Int32) -> Bool
    /// `true` if the process still exists (`kill(pid, 0) == 0`).
    func isAlive(pid: Int32) -> Bool
}

struct ResetOutcome: Equatable {
    let killedPids: [Int32]
    let failedPids: [Int32]          // signal failed, or still alive after the grace period
    let refusedUnknownOccupant: Bool // port 47100 is held by a non-design-canvas process, untouched
    let hadNothingToKill: Bool
}

/// Pure-ish orchestration over injected effects. Kills ONLY processes whose full command line
/// contains the exact `serverEntry` absolute path as a whitespace-bounded token — this is the
/// entire safety boundary, so it is deliberately the only place that decides who gets signaled.
///
/// `reset()` BLOCKS (real `sleep` between `isAlive` grace checks, up to ~1s per surviving pid),
/// so production callers must run it off the main actor — `AppModel.resetProcesses()` hops via
/// `Task.detached`. `@unchecked Sendable` is sound: every stored property is a `let`, and the
/// production adapters (`PgrepProcessQuery`, `PosixSignaler`) are stateless structs.
final class ProcessResetService: @unchecked Sendable {
    private let query: ProcessQuerying
    private let signaling: ProcessSignaling
    private let graceAttempts: Int
    private let sleep: (TimeInterval) -> Void

    /// - graceAttempts: how many times to re-check `isAlive` (with `sleep` between each) after a
    ///   successful SIGTERM before giving up and reporting the pid as failed. Production default
    ///   is ~1s total (10 x 0.1s); tests inject `graceAttempts` small and `sleep` as a no-op so
    ///   they never actually wait.
    init(
        query: ProcessQuerying,
        signaling: ProcessSignaling,
        graceAttempts: Int = 10,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.query = query
        self.signaling = signaling
        self.graceAttempts = graceAttempts
        self.sleep = sleep
    }

    /// Idempotent by construction: with nothing left to find (or nothing left after filtering),
    /// this returns `hadNothingToKill = true` and sends no signals — so running it twice in a row
    /// reports "nothing to kill" on the second run.
    ///
    /// Two reset sources feed the same verify-then-signal pipeline: the *configured*
    /// `serverEntry` (what this app is set up to launch), and — when `lastProbe` is a healthy
    /// response reporting a *different* `serverEntry` — that reported path too. The second
    /// source exists because a stale daemon from another checkout/build answers `/v1/health` as
    /// design-canvas but with its own absolute path baked into its argv; scanning only the
    /// configured path would let it survive reset and crash-loop the supervisor forever. The
    /// health report is only a HINT for where to look — `isVerifiedHelper`'s ps-backed
    /// boundary-token check is the only thing that can ever trigger a signal, so a lying or
    /// stale health response that doesn't correspond to any real process on disk kills nothing.
    func reset(serverEntry: String, lastProbe: HealthProbeResult, ownChildPid: Int32?) -> ResetOutcome {
        let refusedUnknownOccupant = Self.isUnknownOccupant(lastProbe)

        var verified = Self.verifiedCandidates(matching: serverEntry, query: query, ownChildPid: ownChildPid)

        if case .healthy(let health) = lastProbe,
           health.instanceId != nil,
           let reportedServerEntry = health.serverEntry,
           reportedServerEntry != serverEntry {
            let alreadyFound = Set(verified.map(\.pid))
            let reportedVerified = Self.verifiedCandidates(matching: reportedServerEntry, query: query, ownChildPid: ownChildPid)
            verified += reportedVerified.filter { !alreadyFound.contains($0.pid) }
        }

        guard !verified.isEmpty else {
            return ResetOutcome(
                killedPids: [],
                failedPids: [],
                refusedUnknownOccupant: refusedUnknownOccupant,
                hadNothingToKill: true
            )
        }

        var killed: [Int32] = []
        var failed: [Int32] = []
        for candidate in verified {
            guard signaling.terminate(pid: candidate.pid) else {
                failed.append(candidate.pid)
                continue
            }
            if waitForExit(candidate.pid) {
                killed.append(candidate.pid)
            } else {
                failed.append(candidate.pid)
            }
        }
        return ResetOutcome(
            killedPids: killed,
            failedPids: failed,
            refusedUnknownOccupant: refusedUnknownOccupant,
            hadNothingToKill: false
        )
    }

    /// Queries candidates for one `serverEntry` path and applies the same safety filter
    /// (`isVerifiedHelper` + own-child exclusion) used by both reset sources. A query failure
    /// (pgrep/ps unavailable, etc.) must never be treated as "safe to kill everything" — it
    /// degrades to "found nothing", which is the safe direction.
    private static func verifiedCandidates(matching serverEntry: String, query: ProcessQuerying, ownChildPid: Int32?) -> [ProcessCandidate] {
        let rawCandidates = (try? query.candidates(matching: serverEntry)) ?? []
        return rawCandidates.filter { candidate in
            isVerifiedHelper(candidate, serverEntry: serverEntry) && candidate.pid != ownChildPid
        }
    }

    private func waitForExit(_ pid: Int32) -> Bool {
        guard signaling.isAlive(pid: pid) else { return true }
        for _ in 0..<graceAttempts {
            sleep(0.1)
            if !signaling.isAlive(pid: pid) { return true }
        }
        return false
    }

    /// Rule 1: the command line must contain the exact `serverEntry` absolute path as a
    /// whitespace-BOUNDED token (checked against real `ps` output, not a guess from the pgrep
    /// match alone). Raw substring containment is NOT enough: it would also match a process
    /// running a sibling file like `<serverEntry>.bak`/`.map`/`.log`, or `serverEntry` appearing
    /// as the suffix of a longer path like `/backup<serverEntry>` — different files whose
    /// processes must never be signaled.
    /// Rule 2: the command line must ALSO carry a whitespace-bounded `--http` or `--channel`
    /// token — every design-canvas helper runs with exactly one of these (`NodeProcessRunner`
    /// spawns `--http`, Claude Code spawns `--channel`). This closes the residual class where a
    /// crafted/stale health response names a real user-owned script path: even after the exact
    /// path match, an arbitrary `node <path>` process without a mode flag never qualifies.
    /// Rule 3 (defense in depth): never signal anything whose argv[0] looks like the `claude`
    /// binary itself, even if the path happened to appear later in its argv — the `node
    /// <serverEntry> --http`/`--channel` helpers this service targets never have `claude` as
    /// argv[0], so this can only ever exclude, never include, a real helper.
    private static func isVerifiedHelper(_ candidate: ProcessCandidate, serverEntry: String) -> Bool {
        guard containsBoundedToken(candidate.command, serverEntry) else { return false }
        guard containsBoundedToken(candidate.command, "--http")
            || containsBoundedToken(candidate.command, "--channel") else { return false }
        let argv0 = candidate.command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let executableBase = (argv0 as NSString).lastPathComponent
        return executableBase != "claude"
    }

    /// True iff `token` occurs in `command` preceded by start-of-string or whitespace AND
    /// followed by end-of-string or whitespace. Implemented as a scan over every occurrence
    /// (rather than splitting the command on whitespace) so a `serverEntry` path that itself
    /// contains a space would still be matchable in principle.
    private static func containsBoundedToken(_ command: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var searchRange = command.startIndex..<command.endIndex
        while let range = command.range(of: token, range: searchRange) {
            let boundedBefore = range.lowerBound == command.startIndex
                || command[command.index(before: range.lowerBound)].isWhitespace
            let boundedAfter = range.upperBound == command.endIndex
                || command[range.upperBound].isWhitespace
            if boundedBefore && boundedAfter { return true }
            guard range.lowerBound < command.endIndex else { break }
            searchRange = command.index(after: range.lowerBound)..<command.endIndex
        }
        return false
    }

    private static func isUnknownOccupant(_ probe: HealthProbeResult) -> Bool {
        switch probe {
        case .foreignResponse, .timedOut, .badStatus:
            return true
        case .refused, .healthy:
            return false
        }
    }
}

/// Real query adapter: `pgrep -f <serverEntry>` to find candidate pids, then `ps -o
/// pid=,command=` to read back their exact command lines for verification. Thin — all filtering
/// safety logic lives in `ProcessResetService`. Manual-verified, not unit-tested (matches
/// `NodeProcessRunner`'s convention — tests use fakes only, never real process lookups).
struct PgrepProcessQuery: ProcessQuerying {
    func candidates(matching serverEntry: String) throws -> [ProcessCandidate] {
        let pids = try runPgrep(matching: serverEntry)
        guard !pids.isEmpty else { return [] }
        return try runPs(pids: pids)
    }

    private func runPgrep(matching serverEntry: String) throws -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", serverEntry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func runPs(pids: [Int32]) throws -> [ProcessCandidate] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,command=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = trimmed.firstIndex(of: " ") else { return nil }
            guard let pid = Int32(trimmed[trimmed.startIndex..<spaceIndex]) else { return nil }
            let command = trimmed[trimmed.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces)
            return ProcessCandidate(pid: pid, command: String(command))
        }
    }
}

/// Real signaling adapter: POSIX `kill(2)`. `terminate` sends SIGTERM only — SIGKILL is never
/// used anywhere in this file, matching the absolute safety rule.
struct PosixSignaler: ProcessSignaling {
    func terminate(pid: Int32) -> Bool {
        if kill(pid, SIGTERM) == 0 { return true }
        return Self.errnoMeansAlreadyDead(errno)
    }

    /// ESRCH = "no such process": the target is already gone, which is the goal of terminate —
    /// report success so an already-exited helper doesn't land in `failedPids`. Every other
    /// errno (EPERM, EINVAL, …) stays a failure. Pure so it's unit-testable without ever
    /// signaling a real process.
    static func errnoMeansAlreadyDead(_ code: Int32) -> Bool {
        code == ESRCH
    }

    func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}
