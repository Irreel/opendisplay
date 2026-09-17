import Foundation

/// Where a frozen frame waits out a link drop, and what stops the sketch it
/// belongs to being uploaded twice.
///
/// The iPad answers a link loss in SENDING by keeping the sketch and re-sending
/// it after the next `hello` (plan ruling 5, `DrawModeStateMachine`). By then
/// the sender has usually torn the `DeviceSession` down and built a fresh one,
/// so the `CanvasSession` that froze the frame — and held it — is gone. The
/// frame therefore cannot live only inside a session: it is parked here, keyed
/// by the device's install id, and the session that serves the reconnect looks
/// for it when an `annotation` arrives and it holds none itself.
///
/// `CanvasHub` owns one of these for every device it serves, because the hub is
/// the thing that outlives sessions. A session built without one (tests) gets
/// its own, which makes the parking invisible: it then only ever finds what
/// that same session parked.
///
/// Thread-safe: sessions read and write it from the sender's serial queue,
/// which is a different queue per device, and the hub hands the same instance
/// to all of them. Nothing here does I/O or image work, so the lock is never
/// held across an await.
final class CanvasCaptureParkingLot {

    /// How long a parked frame stays usable. A full-resolution `CGImage` is
    /// megabytes, and a device that never comes back must not pin one for the
    /// app's whole life.
    static let expiry: TimeInterval = 600

    private struct Parked {
        let capture: UploadPipeline.FreezeCapture
        let at: Date
    }

    private let lock = NSLock()
    /// One per install id: a device has one Draw Mode at a time, so a second
    /// freeze replaces the first rather than queueing behind it.
    private var parked: [String: Parked] = [:]
    /// The `t` of the last `annotation` accepted from each install id. Not
    /// expired with the frame: it is two words per device, and dropping it is
    /// what would let a re-send upload a second copy of a round.
    private var lastAcceptedT: [String: Double] = [:]

    // MARK: - The frozen frame

    func park(_ capture: UploadPipeline.FreezeCapture, installID: String, at: Date) {
        lock.lock()
        parked[installID] = Parked(capture: capture, at: at)
        lock.unlock()
    }

    /// The frame parked for this device, unless it has expired — in which case
    /// it is dropped here and now, so nothing has to sweep on a timer.
    func parkedCapture(installID: String, now: Date) -> UploadPipeline.FreezeCapture? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = parked[installID] else { return nil }
        guard now.timeIntervalSince(entry.at) <= Self.expiry else {
            parked.removeValue(forKey: installID)
            return nil
        }
        return entry.capture
    }

    /// Called when an annotation has consumed the frame: the round now carries
    /// its own copy, and nothing else will ever want this one.
    func removeParkedCapture(installID: String) {
        lock.lock()
        parked.removeValue(forKey: installID)
        lock.unlock()
    }

    // MARK: - Round identity

    /// True when this device already had an `annotation` with this `t`
    /// accepted. The iPad re-sends byte-identical bytes, so `t` is stable and
    /// identifies the round (`CanvasModel.pendingAnnotation`).
    func hasAccepted(t: Double, installID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastAcceptedT[installID] == t
    }

    func recordAccepted(t: Double, installID: String) {
        lock.lock()
        lastAcceptedT[installID] = t
        lock.unlock()
    }
}
