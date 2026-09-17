import Foundation

/// Owns the daemon's round-update stream on behalf of every connected device
/// and fans each update out to the session it names.
///
/// One stream, not one per session: the daemon emits `round.updated` for all
/// devices on a single SSE connection (`DaemonClient.roundUpdates()`), and a
/// reconnect per device would multiply that connection by however many iPads
/// are attached. Sessions are registered weakly, so the app deciding a device
/// is gone is all it takes to stop delivering to it.
@MainActor
final class CanvasHub {
    private struct WeakSession {
        weak var session: CanvasSession?
    }

    private let daemon: DaemonAPI
    private let status: CanvasStatus
    private var sessions: [WeakSession] = []
    private var consumer: Task<Void, Never>?
    /// Outlives sessions, which is the whole point: a frozen frame and the
    /// identity of the round it belongs to wait here while the sender rebuilds
    /// the session a link drop killed (C1).
    private let parking = CanvasCaptureParkingLot()

    init(daemon: DaemonAPI, status: CanvasStatus) {
        self.daemon = daemon
        self.status = status
    }

    /// A hub that goes away without `stop()` would otherwise leave its
    /// consumer — and the daemon's SSE connection under it — running until
    /// the next update happened to arrive.
    deinit {
        consumer?.cancel()
    }

    /// A session for one device, wired to the same daemon and status and
    /// registered for round updates.
    func makeSession(deviceName: String) -> CanvasSession {
        let session = CanvasSession(deviceName: deviceName, daemon: daemon, status: status, parking: parking)
        prune()
        sessions.append(WeakSession(session: session))
        return session
    }

    /// Registered sessions still alive, for the status UI and for tests;
    /// reading it prunes the ones that are not.
    var sessionCount: Int {
        prune()
        return sessions.count
    }

    /// Starts consuming the daemon's round updates. Calling it again while
    /// one consumer is running does nothing.
    func start() {
        guard consumer == nil else { return }
        let updates = daemon.roundUpdates()
        consumer = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                self.deliver(update)
            }
        }
    }

    func stop() {
        consumer?.cancel()
        consumer = nil
    }

    /// Offered to every live session; each one decides whether the update is
    /// for its device (`CanvasSession.deliver`).
    private func deliver(_ update: RoundUpdate) {
        prune()
        for entry in sessions {
            entry.session?.deliver(update)
        }
    }

    private func prune() {
        sessions.removeAll { $0.session == nil }
    }
}
