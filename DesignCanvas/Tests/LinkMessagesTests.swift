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

    /// Every Mac here has proven its key. A cable is physical intent, so
    /// plugging one in takes over; the Mac being mirrored, back on a new
    /// connection, is recognised by its key; another Mac over WiFi waits for
    /// the user, whatever the session runs on.
    func test_whoTakesTheSessionAtOnceAndWhoIsAskedAbout() {
        let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
        func admit(_ current: String, _ currentKey: Data?, _ newcomer: String, _ newcomerKey: Data?) -> CanvasReceiver.Admission {
            CanvasReceiver.admission(currentTransport: current, currentMacKey: currentKey,
                                     newcomerTransport: newcomer, newcomerMacKey: newcomerKey)
        }
        XCTAssertEqual(admit("WiFi", a, "WiFi", a), .adopt, "the session's own Mac, reconnecting")
        XCTAssertEqual(admit("USB", a, "WiFi", a), .adopt, "the same Mac, off its cable")
        XCTAssertEqual(admit("WiFi", a, "WiFi", b), .ask)
        XCTAssertEqual(admit("USB", a, "WiFi", b), .ask)
        XCTAssertEqual(admit("WiFi", a, "USB", b), .adopt, "plugging a cable in takes over")
    }

    func test_aHelloCarriesItsKeysAndRefusesTheWrongLengths() {
        let key = Data(repeating: 7, count: 32), eph = Data(repeating: 8, count: 32), sig = Data(repeating: 9, count: 64)
        let hello = HelloMessage(version: 2, role: .ipad, name: "iPad", installID: "ID", device: "iPad",
                                 key: key, ephemeral: eph, signature: sig)
        XCTAssertEqual(HelloMessage(json: hello.json), hello)
        var json = hello.json
        json["key"] = Data(repeating: 7, count: 31).base64EncodedString()
        json["sig"] = "not base64"
        let damaged = HelloMessage(json: json)
        XCTAssertNil(damaged?.key)
        XCTAssertNil(damaged?.signature)
        XCTAssertEqual(damaged?.ephemeral, eph)
    }

    func test_byeRoundTripsAndAnUnknownReasonIsQuit() {
        XCTAssertEqual(ByeMessage(json: ByeMessage(reason: .replaced).json).reason, .replaced)
        XCTAssertEqual(ByeMessage(json: ["reason": "bored"]).reason, .quit)
        XCTAssertEqual(ByeMessage(json: [:]).reason, .quit)
    }
}
