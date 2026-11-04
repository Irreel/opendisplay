// Which iPads the Mac can see, one entry per physical device, and which of
// them it should connect to on its own. Pure, so the merging and the policy
// are tested without a cable or a network.

import Foundation
import Network

/// An iPad attached over USB, as usbmuxd reports it.
struct USBEntry: Equatable {
    var udid: String
    /// The lockdown name ("Zhao's iPad"), once it has been read.
    var name: String?
}

/// An iPad advertising Design Canvas on the local network.
struct ServiceEntry: Equatable {
    /// The Bonjour service name: the name the iPad's user gave it.
    var name: String
    /// Its install id, from the TXT record. Absent until the record arrives.
    var installID: String?
    var endpoint: NWEndpoint
}

/// One physical iPad, however many ways it can be reached.
struct VisibleDevice: Equatable, Identifiable {
    /// `id:<install id>` once the install id is known; `usb:<udid>` or
    /// `wifi:<service name>` until then.
    var id: String
    var installID: String?
    var usb: USBEntry?
    var service: ServiceEntry?

    var name: String { usb?.name ?? service?.name ?? "iPad" }

    /// Every way to reach it. The engine dials WiFi only for an iPad the user
    /// trusted there (`ConnectPolicy`).
    var paths: LinkPaths {
        LinkPaths(usbUDID: usb?.udid, wifi: service?.endpoint, wifiInstallID: service?.installID)
    }

    /// "USB", "WiFi" or "USB · WiFi".
    var transportLabel: String {
        switch (usb != nil, service != nil) {
        case (true, true): return "USB · WiFi"
        case (true, false): return "USB"
        case (false, true): return "WiFi"
        case (false, false): return ""
        }
    }
}

enum DeviceDirectory {
    /// Folds the cabled devices and the advertised services into one entry
    /// per iPad. A USB device and a service are the same iPad when the
    /// install id this Mac learned for that cable (from the iPad's hello over
    /// USB) equals the one the service advertises. Only a cable whose iPad has
    /// never said hello falls back to a matching name: once the id is known,
    /// a service that does not advertise it is someone else.
    static func merge(usb: [USBEntry], services: [ServiceEntry],
                      installIDByUDID: [String: String]) -> [VisibleDevice] {
        var remaining = services
        var devices: [VisibleDevice] = []
        for entry in usb.sorted(by: { $0.udid < $1.udid }) {
            let known = installIDByUDID[entry.udid]
            let twinIndex = remaining.firstIndex { service in
                if let known { return service.installID == known }
                guard let name = entry.name else { return false }
                return service.name == name
            }
            let twin = twinIndex.map { remaining.remove(at: $0) }
            let installID = known ?? twin?.installID
            devices.append(VisibleDevice(id: installID.map { "id:\($0)" } ?? "usb:\(entry.udid)",
                                         installID: installID, usb: entry, service: twin))
        }
        for service in remaining.sorted(by: { $0.name < $1.name }) {
            devices.append(VisibleDevice(id: service.installID.map { "id:\($0)" } ?? "wifi:\(service.name)",
                                         installID: service.installID, usb: nil, service: service))
        }
        return devices
    }
}

/// When the Mac connects to an iPad without being asked.
///
/// - Plugging an iPad in connects it, unless the user disconnected that iPad.
/// - An iPad the user connected over WiFi with a click is connected again
///   whenever it is advertised.
/// - Anything else waits for a click on Connect.
///
/// The WiFi rule rests on the install id in the iPad's Bonjour TXT record,
/// which anything on the LAN can advertise; a dialed peer receives the screen.
/// So only the user's own WiFi click grants it — a cable does not — and the
/// real fix is a pairing step (spec/TODOS.md, encrypted WiFi transport).
struct ConnectPolicy: Equatable {
    /// Install ids the user connected over WiFi.
    var trusted: Set<String> = []
    /// Install ids and udids the user disconnected: never auto-connected.
    var disconnectedIDs: Set<String> = []
    var disconnectedUDIDs: Set<String> = []

    func shouldAutoConnect(_ device: VisibleDevice) -> Bool {
        if let id = device.installID, disconnectedIDs.contains(id) { return false }
        if let usb = device.usb { return !disconnectedUDIDs.contains(usb.udid) }
        if let id = device.installID, device.service != nil { return trusted.contains(id) }
        return false
    }

    /// The user connected this iPad. A click on an iPad that can only be
    /// reached over WiFi is what trusts it there.
    mutating func connected(_ device: VisibleDevice) {
        if let id = device.installID {
            disconnectedIDs.remove(id)
            if device.usb == nil, device.service != nil { trusted.insert(id) }
        }
        if let udid = device.usb?.udid { disconnectedUDIDs.remove(udid) }
    }

    /// A WiFi connection the user asked for reached the iPad's hello. Covers
    /// a click on a service whose TXT record had not named the iPad yet.
    mutating func connectedOverWiFi(installID: String) {
        disconnectedIDs.remove(installID)
        trusted.insert(installID)
    }

    /// The user disconnected this iPad: it stays off until they connect it.
    mutating func disconnected(installID: String?, udid: String?) {
        if let installID {
            trusted.remove(installID)
            disconnectedIDs.insert(installID)
        }
        if let udid { disconnectedUDIDs.insert(udid) }
    }
}
