// The live sources behind `DeviceDirectory`: usbmuxd for cabled iPads and a
// Bonjour browser for the ones on WiFi. Main actor; reports every change.

import Foundation
import Network

@MainActor
final class DeviceWatcher {
    private(set) var usb: [USBEntry] = []
    private(set) var services: [ServiceEntry] = []
    var onChange: (() -> Void)?

    private var usbWatcher: UsbmuxDeviceWatcher?
    private var browser: NWBrowser?
    /// Each service's install id, by name, while it is advertised
    /// (`DeviceDirectory.keepingInstallIDs`).
    private var knownInstallIDs: [String: String] = [:]

    func start() {
        guard usbWatcher == nil else { return }
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            guard let self else { return }
            let entries = devices.map { USBEntry(udid: $0.udid, name: $0.name) }
            guard entries != self.usb else { return }
            self.usb = entries
            self.onChange?()
        }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: CanvasWire.serviceType, domain: nil),
                                using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let entries = results.compactMap(Self.entry(from:))
            DispatchQueue.main.async {
                guard let self else { return }
                let kept = DeviceDirectory.keepingInstallIDs(entries, known: self.knownInstallIDs)
                self.knownInstallIDs = kept.known
                guard kept.services != self.services else { return }
                self.services = kept.services
                self.onChange?()
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.info("bonjour: browser failed (\(error))")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        usbWatcher = nil
        usb = []
        services = []
        knownInstallIDs = [:]
    }

    private nonisolated static func entry(from result: NWBrowser.Result) -> ServiceEntry? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var installID: String?
        if case .bonjour(let txt) = result.metadata {
            installID = txt[CanvasWire.txtIDKey].flatMap { $0.isEmpty ? nil : $0 }
        }
        return ServiceEntry(name: name, installID: installID, endpoint: result.endpoint)
    }
}
