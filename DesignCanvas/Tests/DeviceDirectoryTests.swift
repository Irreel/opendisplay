import Network
import XCTest

/// One entry per physical iPad, and when the Mac connects one on its own.
final class DeviceDirectoryTests: XCTestCase {

    private func service(_ name: String, id: String?) -> ServiceEntry {
        ServiceEntry(name: name, installID: id,
                     endpoint: .service(name: name, type: CanvasWire.serviceType, domain: "local.", interface: nil))
    }

    // MARK: - merge

    func test_aCableAndAServiceWithTheLearnedInstallIdAreOneIPad() {
        let devices = DeviceDirectory.merge(usb: [USBEntry(udid: "U1", name: "Lockdown name")],
                                            services: [service("Studio iPad", id: "ID1")],
                                            installIDByUDID: ["U1": "ID1"])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "id:ID1")
        XCTAssertEqual(devices[0].transportLabel, "USB · WiFi")
        XCTAssertEqual(devices[0].paths, LinkPaths(usbUDID: "U1", wifi: devices[0].service?.endpoint,
                                                   wifiInstallID: "ID1"))
    }

    func test_withNoLearnedIdTheNameIsTheFallback() {
        let devices = DeviceDirectory.merge(usb: [USBEntry(udid: "U1", name: "Studio iPad")],
                                            services: [service("Studio iPad", id: "ID1")],
                                            installIDByUDID: [:])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].installID, "ID1")
        XCTAssertEqual(devices[0].id, "id:ID1")
    }

    /// Once the cable's iPad is known, the name is no longer evidence: a
    /// service that does not advertise that id is another device.
    func test_aKnownCableDoesNotPairWithAServiceThatAdvertisesNoId() {
        let devices = DeviceDirectory.merge(usb: [USBEntry(udid: "U1", name: "Studio iPad")],
                                            services: [service("Studio iPad", id: nil)],
                                            installIDByUDID: ["U1": "ID1"])
        XCTAssertEqual(devices.map(\.id), ["id:ID1", "wifi:Studio iPad"])
        XCTAssertNil(devices[0].service)
    }

    func test_differentInstallIdsAreTwoIPadsEvenWithTheSameName() {
        let devices = DeviceDirectory.merge(usb: [USBEntry(udid: "U1", name: "iPad")],
                                            services: [service("iPad", id: "ID2")],
                                            installIDByUDID: ["U1": "ID1"])
        XCTAssertEqual(devices.map(\.id), ["id:ID1", "id:ID2"])
    }

    func test_aServiceKeepsItsInstallIdWhenAnUpdateComesWithoutItsRecord() {
        let first = DeviceDirectory.keepingInstallIDs([service("Studio iPad", id: "ID1")], known: [:])
        // The cable is unplugged: the same service, reported again with no record.
        let second = DeviceDirectory.keepingInstallIDs([service("Studio iPad", id: nil)], known: first.known)
        XCTAssertEqual(second.services.map(\.installID), ["ID1"])
    }

    func test_aServiceThatLeavesTakesItsRememberedInstallIdWithIt() {
        let first = DeviceDirectory.keepingInstallIDs([service("Studio iPad", id: "ID1")], known: [:])
        let gone = DeviceDirectory.keepingInstallIDs([], known: first.known)
        let back = DeviceDirectory.keepingInstallIDs([service("Studio iPad", id: nil)], known: gone.known)
        XCTAssertNil(back.services[0].installID)
    }

    func test_aRecordThatArrivesWinsOverTheRememberedInstallId() {
        let first = DeviceDirectory.keepingInstallIDs([service("Studio iPad", id: "ID1")], known: [:])
        let second = DeviceDirectory.keepingInstallIDs([service("Studio iPad", id: "ID2")], known: first.known)
        XCTAssertEqual(second.services.map(\.installID), ["ID2"])
        XCTAssertEqual(second.known, ["Studio iPad": "ID2"])
    }

    func test_unknownDevicesAreKeyedByHowTheyCanBeReached() {
        let devices = DeviceDirectory.merge(usb: [USBEntry(udid: "U9", name: nil)],
                                            services: [service("Kitchen iPad", id: nil)],
                                            installIDByUDID: [:])
        XCTAssertEqual(devices.map(\.id), ["usb:U9", "wifi:Kitchen iPad"])
        XCTAssertEqual(devices[0].name, "iPad")
        XCTAssertEqual(devices[1].name, "Kitchen iPad")
    }

    // MARK: - ConnectPolicy

    private func device(installID: String? = nil, udid: String? = nil, service hasService: Bool = false) -> VisibleDevice {
        VisibleDevice(id: "d", installID: installID,
                      usb: udid.map { USBEntry(udid: $0, name: nil) },
                      service: hasService ? service("iPad", id: installID) : nil)
    }

    func test_pluggingInConnects() {
        XCTAssertTrue(ConnectPolicy().shouldAutoConnect(device(udid: "U1")))
    }

    func test_aServiceAloneWaitsForAClick() {
        XCTAssertFalse(ConnectPolicy().shouldAutoConnect(device(installID: "ID1", service: true)))
    }

    /// Once paired (by cable or WiFi), the iPad reconnects over WiFi too: the
    /// session proves its key, so an impostor with its id gets nothing.
    func test_aPairedIPadReconnectsOverWiFi() {
        var policy = ConnectPolicy()
        policy.paired.insert("ID1")
        XCTAssertTrue(policy.shouldAutoConnect(device(installID: "ID1", service: true)))
    }

    func test_aClickUndoesADisconnect() {
        var policy = ConnectPolicy()
        policy.paired.insert("ID1")
        policy.disconnected(installID: "ID1", udid: "U1")
        let both = device(installID: "ID1", udid: "U1", service: true)
        XCTAssertFalse(policy.shouldAutoConnect(both))
        policy.connected(both)
        XCTAssertTrue(policy.shouldAutoConnect(both))
    }

    func test_aDisconnectedIPadStaysOffOnEveryTransport() {
        var policy = ConnectPolicy()
        policy.paired.insert("ID1")
        policy.disconnected(installID: "ID1", udid: "U1")
        XCTAssertFalse(policy.shouldAutoConnect(device(installID: "ID1", service: true)))
        XCTAssertFalse(policy.shouldAutoConnect(device(installID: "ID1", udid: "U1")))
        XCTAssertFalse(policy.shouldAutoConnect(device(udid: "U1")))
    }

    func test_aDeviceWithoutAPathIsNeverAutoConnected() {
        var policy = ConnectPolicy()
        policy.paired.insert("ID1")
        XCTAssertFalse(policy.shouldAutoConnect(device(installID: "ID1")))
    }
}
