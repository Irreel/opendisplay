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
        XCTAssertEqual(devices[0].paths, LinkPaths(usbUDID: "U1", wifi: devices[0].service?.endpoint))
    }

    func test_withNoLearnedIdTheNameIsTheFallback() {
        let devices = DeviceDirectory.merge(usb: [USBEntry(udid: "U1", name: "Studio iPad")],
                                            services: [service("Studio iPad", id: "ID1")],
                                            installIDByUDID: [:])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].installID, "ID1")
        XCTAssertEqual(devices[0].id, "id:ID1")
    }

    func test_differentInstallIdsAreTwoIPadsEvenWithTheSameName() {
        let devices = DeviceDirectory.merge(usb: [USBEntry(udid: "U1", name: "iPad")],
                                            services: [service("iPad", id: "ID2")],
                                            installIDByUDID: ["U1": "ID1"])
        XCTAssertEqual(devices.map(\.id), ["id:ID1", "id:ID2"])
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

    func test_aWiFiClickTrustsTheIPadOverWiFi() {
        var policy = ConnectPolicy()
        let wifiOnly = device(installID: "ID1", service: true)
        policy.connected(wifiOnly)
        XCTAssertTrue(policy.shouldAutoConnect(wifiOnly))
    }

    func test_aWiFiHelloTheUserAskedForTrustsTheIPad() {
        var policy = ConnectPolicy()
        policy.connectedOverWiFi(installID: "ID1")
        XCTAssertTrue(policy.shouldAutoConnect(device(installID: "ID1", service: true)))
    }

    /// The Bonjour id anything on the LAN can advertise; plugging an iPad in
    /// must not make the Mac dial whatever claims that id over WiFi.
    func test_aCableDoesNotTrustTheIPadOverWiFi() {
        var policy = ConnectPolicy()
        let cabled = device(installID: "ID1", udid: "U1", service: true)
        XCTAssertTrue(policy.shouldAutoConnect(cabled))
        policy.connected(cabled)
        XCTAssertFalse(policy.trusted.contains("ID1"))
        XCTAssertFalse(policy.shouldAutoConnect(device(installID: "ID1", service: true)))
    }

    func test_aClickUndoesADisconnect() {
        var policy = ConnectPolicy()
        policy.disconnected(installID: "ID1", udid: "U1")
        let both = device(installID: "ID1", udid: "U1", service: true)
        XCTAssertFalse(policy.shouldAutoConnect(both))
        policy.connected(both)
        XCTAssertTrue(policy.shouldAutoConnect(both))
    }

    func test_aDisconnectedIPadStaysOffOnEveryTransport() {
        var policy = ConnectPolicy()
        policy.connectedOverWiFi(installID: "ID1")
        policy.disconnected(installID: "ID1", udid: "U1")
        XCTAssertFalse(policy.shouldAutoConnect(device(installID: "ID1", service: true)))
        XCTAssertFalse(policy.shouldAutoConnect(device(installID: "ID1", udid: "U1")))
        XCTAssertFalse(policy.shouldAutoConnect(device(udid: "U1")))
    }

    func test_aDeviceWithoutAPathIsNeverAutoConnected() {
        var policy = ConnectPolicy()
        policy.connectedOverWiFi(installID: "ID1")
        XCTAssertFalse(policy.shouldAutoConnect(device(installID: "ID1")))
    }
}
