import Foundation

/// The canvas sessions, one per iPad, keyed by install id. Thread-safe: links
/// look a session up from the stream queue when their iPad says hello, and the
/// hub walks them from the main actor.
final class CanvasSessionStore {
    private let lock = NSLock()
    private var sessions: [String: CanvasSession] = [:]
    private let make: (_ installID: String, _ deviceName: String) -> CanvasSession

    init(make: @escaping (_ installID: String, _ deviceName: String) -> CanvasSession) {
        self.make = make
    }

    /// The session for this iPad, created the first time it says hello. It is
    /// kept for the app's life: a reconnect, even minutes later, finds the
    /// frame it froze and the round it was sending exactly where they were.
    func session(installID: String, deviceName: String) -> CanvasSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[installID] { return existing }
        let created = make(installID, deviceName)
        sessions[installID] = created
        return created
    }

    var all: [CanvasSession] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values)
    }
}

/// Owns the daemon's round-update and session streams on behalf of every iPad
/// and fans each update out to the sessions.
///
/// One stream, not one per iPad: the daemon emits `round.updated` for all
/// devices on a single SSE connection (`DaemonClient.roundUpdates()`), and a
/// reconnect per device would multiply that connection by however many iPads
/// are attached.
@MainActor
final class CanvasHub {
    private let daemon: DaemonAPI
    private let status: CanvasStatus
    nonisolated let store: CanvasSessionStore
    private var consumer: Task<Void, Never>?
    private var sessionsConsumer: Task<Void, Never>?

    init(daemon: DaemonAPI, status: CanvasStatus, frames: CleanFrameSource) {
        self.daemon = daemon
        self.status = status
        store = CanvasSessionStore { installID, deviceName in
            CanvasSession(installID: installID, deviceName: deviceName,
                          daemon: daemon, status: status, frames: frames)
        }
    }

    /// A hub that goes away without `stop()` would otherwise leave its
    /// consumers — and the daemon's SSE connections under them — running until
    /// the next update happened to arrive.
    deinit {
        consumer?.cancel()
        sessionsConsumer?.cancel()
    }

    /// Sketches accepted from every device and not yet uploaded or dropped.
    /// The menu shows this, because a daemon that is down otherwise leaves the
    /// user with no sign that their rounds are still queued (I3).
    var pendingUploads: Int {
        store.all.reduce(0) { $0 + $1.pendingUploadCount }
    }

    /// Starts consuming the daemon's streams. Calling it again while they run
    /// does nothing.
    func start() {
        guard consumer == nil else { return }
        let updates = daemon.roundUpdates()
        consumer = Task { [weak self] in
            for await event in updates {
                guard let self else { return }
                switch event {
                case .connected:
                    self.resendSnapshots()
                case .update(let update):
                    self.deliver(update)
                }
            }
        }
        // The Claude Code sessions and their state. On the stream, not the app's
        // 2 s health poll, so "Waiting at the Mac" reaches the iPad as it happens.
        let sessionUpdates = daemon.sessionUpdates()
        sessionsConsumer = Task { [weak self] in
            for await snapshot in sessionUpdates {
                guard let self else { return }
                self.publish(snapshot.message)
            }
        }
    }

    func stop() {
        consumer?.cancel()
        consumer = nil
        sessionsConsumer?.cancel()
        sessionsConsumer = nil
    }

    /// The menu's verdict on the Claude Code hop changed, or may have: every
    /// iPad whose status it changes is told.
    func setChannelState(_ state: ChannelState) {
        guard state != status.channelState else { return }
        status.channelState = state
        for session in store.all { session.sendStatus() }
    }

    /// Records the list and tells every connected iPad, but only when it
    /// actually changed: the stream repeats itself on every reconnect. The
    /// target's folder is the `status` project, so that may change with it.
    private func publish(_ message: SessionsMessage) {
        guard message != status.sessions else { return }
        status.sessions = message
        for session in store.all {
            session.sendSessions()
            session.sendStatus()
        }
    }

    /// A (re)connection of the rounds stream. The daemon replays nothing, so
    /// any `round.updated` emitted while the stream was down is lost — every
    /// connected device is given a fresh snapshot instead (I2).
    private func resendSnapshots() {
        for session in store.all { session.resendSnapshot() }
    }

    /// Offered to every session; each one decides whether the update is for
    /// its device (`CanvasSession.deliver`).
    private func deliver(_ update: RoundUpdate) {
        for session in store.all { session.deliver(update) }
    }
}
