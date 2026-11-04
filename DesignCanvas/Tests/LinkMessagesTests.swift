import XCTest

/// The messages that keep a link up (spec/wire-protocol.md section 5).
final class LinkMessagesTests: XCTestCase {

    func test_anIPadHelloRoundTrips() {
        let hello = HelloMessage(version: 1, role: .ipad, name: "Studio iPad", installID: "ABC", device: "iPad")
        XCTAssertEqual(HelloMessage(json: hello.json), hello)
    }

    func test_aMacHelloCarriesNoIPadFields() {
        let hello = HelloMessage(version: 1, role: .mac, name: "Zhao's MacBook Pro")
        XCTAssertEqual(Set(hello.json.keys), ["v", "role", "name"])
    }

    func test_aHelloWithoutVersionOrRoleIsNotAHello() {
        XCTAssertNil(HelloMessage(json: ["role": "mac"]))
        XCTAssertNil(HelloMessage(json: ["v": 1]))
        XCTAssertNil(HelloMessage(json: ["v": 1, "role": "printer"]))
    }

    func test_aLongNameIsCutAndAnEmptyOneIsAbsent() {
        let long = String(repeating: "n", count: 200)
        XCTAssertEqual(HelloMessage(json: ["v": 1, "role": "mac", "name": long])?.name?.count,
                       CanvasWire.macNameMaxCharacters)
        XCTAssertNil(HelloMessage(json: ["v": 1, "role": "mac", "name": ""])?.name)
    }

    func test_statusRoundTripsAndOmitsAnAbsentProject() {
        let status = StatusMessage(channel: .attached, project: "site")
        XCTAssertEqual(StatusMessage(json: status.json), status)
        XCTAssertNil(StatusMessage(channel: .none, project: nil).json["project"])
    }

    func test_anUnknownChannelReadsAsNone() {
        XCTAssertEqual(StatusMessage(json: ["channel": "teleported"])?.channel, ChannelState.none)
        XCTAssertNil(StatusMessage(json: [:]))
    }

    /// A LAN neighbour can say hello as a Mac; it must not take a cabled
    /// session. USB may still take over from WiFi (plugging in).
    func test_aWiFiHelloNeverEvictsACabledSession() {
        XCTAssertFalse(CanvasReceiver.mayReplace(current: "USB", with: "WiFi"))
        XCTAssertTrue(CanvasReceiver.mayReplace(current: "WiFi", with: "USB"))
        XCTAssertTrue(CanvasReceiver.mayReplace(current: "WiFi", with: "WiFi"))
        XCTAssertTrue(CanvasReceiver.mayReplace(current: "USB", with: "USB"))
    }

    func test_byeRoundTripsAndAnUnknownReasonIsQuit() {
        XCTAssertEqual(ByeMessage(json: ByeMessage(reason: .replaced).json).reason, .replaced)
        XCTAssertEqual(ByeMessage(json: ["reason": "bored"]).reason, .quit)
        XCTAssertEqual(ByeMessage(json: [:]).reason, .quit)
    }
}
