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

    /// A peer's name ends up in a security prompt: nothing in it may break
    /// the prompt's lines or reorder its text.
    func test_aPeersNameLosesControlAndFormattingCharacters() {
        XCTAssertEqual(HelloMessage.displayName("Zhao\u{2019}s\nMac\u{202E}Book\t"), "Zhao\u{2019}s MacBook")
        XCTAssertEqual(HelloMessage.displayName("  Studio    iMac  "), "Studio iMac")
        XCTAssertNil(HelloMessage.displayName("\u{202E}\u{200B}\n"))
        XCTAssertEqual(HelloMessage(json: ["v": 1, "role": "mac", "name": "A\rB\u{0007}C"])?.name, "A BC")
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

    /// A LAN neighbour can say hello as a Mac, so another Mac over WiFi
    /// waits for the user whatever the session runs on. Plugging a cable in
    /// takes over, and the Mac being mirrored comes back without a question.
    func test_whoTakesTheSessionAtOnceAndWhoIsAskedAbout() {
        func admit(_ current: String, _ currentID: String?, _ newcomer: String, _ newcomerID: String?) -> CanvasReceiver.Admission {
            CanvasReceiver.admission(currentTransport: current, currentMacID: currentID,
                                     newcomerTransport: newcomer, newcomerMacID: newcomerID)
        }
        XCTAssertEqual(admit("USB", "MAC-A", "WiFi", "MAC-B"), .ask)
        XCTAssertEqual(admit("WiFi", "MAC-A", "WiFi", "MAC-B"), .ask)
        XCTAssertEqual(admit("WiFi", "MAC-A", "WiFi", nil), .ask)
        XCTAssertEqual(admit("WiFi", nil, "WiFi", nil), .ask)
        XCTAssertEqual(admit("WiFi", "MAC-A", "WiFi", "MAC-A"), .adopt)
        XCTAssertEqual(admit("USB", "MAC-A", "WiFi", "MAC-A"), .adopt)
        XCTAssertEqual(admit("WiFi", "MAC-A", "USB", "MAC-B"), .adopt)
    }

    func test_byeRoundTripsAndAnUnknownReasonIsQuit() {
        XCTAssertEqual(ByeMessage(json: ByeMessage(reason: .replaced).json).reason, .replaced)
        XCTAssertEqual(ByeMessage(json: ["reason": "bored"]).reason, .quit)
        XCTAssertEqual(ByeMessage(json: [:]).reason, .quit)
    }
}
