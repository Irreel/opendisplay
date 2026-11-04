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

    /// Every way to reach it. The engine dials WiFi only for an iPad this Mac
    /// is paired with, or one the user clicked to pair (`ConnectPolicy`).
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

    /// Keeps each service's install id across a browse update that comes
    /// without its TXT record. Unplugging the cable is one: the service loses
    /// the cable's interfaces, the browser reports it again with no record and
    /// does not resolve it again, and the paired iPad would read as a stranger
    /// that may not be dialed over WiFi. Bonjour names are unique on the
    /// network, so the name holds the id until the service is gone; the
    /// session proves the iPad's key whatever the record says.
    static func keepingInstallIDs(_ services: [ServiceEntry],
                                  known: [String: String]) -> (services: [ServiceEntry], known: [String: String]) {
        var kept = services
        var stillKnown: [String: String] = [:]
        for index in kept.indices {
            if kept[index].installID == nil { kept[index].installID = known[kept[index].name] }
            if let id = kept[index].installID { stillKnown[kept[index].name] = id }
        }
        return (kept, stillKnown)
    }
}

/// When the Mac connects to an iPad without being asked.
///
/// - Plugging an iPad in connects it (and, the first time, pairs it), unless
///   the user disconnected that iPad.
/// - An iPad this Mac is paired with is connected again whenever it is
///   advertised on WiFi. The session proves its key either way, so an
///   impostor advertising its install id gets dialed and turned away.
/// - Anything else waits for a click on Connect.
struct ConnectPolicy: Equatable {
    /// Install ids of the iPads this Mac is paired with.
    var paired: Set<String> = []
    /// Install ids and udids the user disconnected: never auto-connected.
    var disconnectedIDs: Set<String> = []
    var disconnectedUDIDs: Set<String> = []

    func shouldAutoConnect(_ device: VisibleDevice) -> Bool {
        if let id = device.installID, disconnectedIDs.contains(id) { return false }
        if let usb = device.usb { return !disconnectedUDIDs.contains(usb.udid) }
        if let id = device.installID, device.service != nil { return paired.contains(id) }
        return false
    }

    /// The user connected this iPad.
    mutating func connected(_ device: VisibleDevice) {
        if let id = device.installID { disconnectedIDs.remove(id) }
        if let udid = device.usb?.udid { disconnectedUDIDs.remove(udid) }
    }

    /// The user disconnected this iPad (or forgot it): it stays off until
    /// they connect it. Pairing is the store's, and outlives this.
    mutating func disconnected(installID: String?, udid: String?) {
        if let installID { disconnectedIDs.insert(installID) }
        if let udid { disconnectedUDIDs.insert(udid) }
    }
}
