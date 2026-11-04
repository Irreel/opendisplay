// The app's owner of the receiver: who this device is (install id, name,
// kind), and the scene and lock lifecycle turned into the receiver's sleep,
// pause and shutdown calls. The UIKit half that `CanvasReceiver` keeps out
// of itself so the test bundle can compile the rest.

import Combine
import SwiftUI
import UIKit

/// "iPad" or "iPhone" — so UI copy names the device the user is holding.
let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

@MainActor
final class ReceiverController: ObservableObject {
    let receiver: CanvasReceiver
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var backgroundToken: UIBackgroundTaskIdentifier = .invalid

    /// Stable per install: the Mac keys everything it remembers about this
    /// device on it, because the service name is user-editable and iOS offers
    /// no public hardware id.
    static let installID: String = {
        if let existing = UserDefaults.standard.string(forKey: "installID") { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "installID")
        return fresh
    }()

    init() {
        // iOS 16+ reports a generic "iPad" for `UIDevice.name` without an
        // entitlement, so a name the user set wins.
        let saved = UserDefaults.standard.string(forKey: "deviceName")
        let name = (saved?.isEmpty == false) ? saved! : UIDevice.current.name
        receiver = CanvasReceiver(configuration: .init(installID: Self.installID,
                                                       deviceKind: deviceKind,
                                                       name: name,
                                                       pairing: KeychainPairingStore(service: "com.designcanvas.pairing.ipad")))
        receiver.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        receiver.start()
    }

    // MARK: - Lock vs app switch vs quit

    // An app switch keeps the session: the assertion buys ~30 s of live
    // pings, and once iOS suspends the app the Mac reads the silence as a
    // drop and redials until it is back. A device lock ends the session at
    // once (nobody can see the mirror), and quitting says goodbye.
    //
    // Lock detection rides the protected-data signal, which fires only with a
    // passcode set and "Require Passcode" at Immediately; otherwise a lock is
    // indistinguishable from an app switch and is treated like one.

    func sceneDidBackground() {
        if !UIApplication.shared.isProtectedDataAvailable {
            Log.info("controller: backgrounded by device lock — sleeping now")
            goToSleep()
            return
        }
        Log.info("controller: app switched away — keeping the session, rendering paused")
        beginBackgroundAssertion()
        receiver.setRenderingPaused(true)
    }

    func sceneDidActivate() {
        endBackgroundAssertion()
        receiver.setRenderingPaused(false)
        receiver.ensureListening()
    }

    func deviceWillLock() {
        Log.info("controller: device locking — sleeping now")
        goToSleep()
    }

    /// Unlock also fires when the user unlocks into another app while this one
    /// is in the background; the real return still comes through the scene.
    func deviceDidUnlock() {
        guard UIApplication.shared.applicationState == .active else { return }
        sceneDidActivate()
    }

    func appWillTerminate() {
        Log.info("controller: app terminating — closing the session")
        receiver.shutDown()
    }

    private func goToSleep() {
        receiver.enterSleep { [weak self] in
            DispatchQueue.main.async { self?.endBackgroundAssertion() }
        }
    }

    private func beginBackgroundAssertion() {
        guard backgroundToken == .invalid else { return }
        backgroundToken = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundToken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundToken)
        backgroundToken = .invalid
    }
}
