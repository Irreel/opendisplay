import XCTest

/// `SenderControlJSON` takes over the `welcome` and `ping` strings MacSender
/// used to interpolate by hand. Those strings are the wire, so the legacy
/// interpolations are reproduced verbatim below as the expected values: a
/// future edit to the builder that changes a byte fails here instead of
/// quietly changing what every receiver in the field parses.
final class SenderControlJSONTests: XCTestCase {

    // MARK: - welcome

    func testWelcomeWithoutCanvasIsByteIdenticalToTheLegacyString() {
        XCTAssertEqual(SenderControlJSON.welcome(pv: 3, min: 1, canvas: false),
                       "{\"type\":\"welcome\",\"pv\":3,\"min\":1}")
    }

    func testWelcomeWithCanvasCarriesTheFlagAndTheSameVersions() throws {
        let object = try parse(SenderControlJSON.welcome(pv: 3, min: 1, canvas: true))
        XCTAssertEqual(object["type"] as? String, "welcome")
        XCTAssertEqual(object["pv"] as? Int, 3)
        XCTAssertEqual(object["min"] as? Int, 1)
        XCTAssertEqual(object["canvas"] as? Bool, true)
    }

    // MARK: - ping

    func testPingWithoutExtrasIsByteIdenticalToTheLegacyString() {
        // schedulePing rounds both percentiles, so they reach the wire as
        // Doubles ("12.0"), not Ints — that is part of the byte identity.
        let inp50 = 12.0
        let inp95 = 34.0
        let built = SenderControlJSON.ping(drops: 7, encDrops: 5, netDrops: 2, pending: 1,
                                           inp50: inp50, inp95: inp95, capFps: 58,
                                           extras: [:])
        XCTAssertEqual(built, legacyPing(dropsTotal: 7, dropsEncTotal: 5, dropsNetTotal: 2,
                                         pendingSends: 1, inp50: inp50, inp95: inp95,
                                         capFps: 58))
        XCTAssertTrue(built.contains("\"inp50\":12.0"), built)
    }

    func testPingWithExtrasCarriesThemAndEveryNumericField() throws {
        let object = try parse(SenderControlJSON.ping(
            drops: 7, encDrops: 5, netDrops: 2, pending: 1,
            inp50: 12, inp95: 34, capFps: 58,
            extras: ["channel": "attached", "project": "site"]))
        XCTAssertEqual(object["type"] as? String, "ping")
        XCTAssertEqual(object["channel"] as? String, "attached")
        XCTAssertEqual(object["project"] as? String, "site")
        XCTAssertEqual(object["drops"] as? Int, 7)
        XCTAssertEqual(object["encDrops"] as? Int, 5)
        XCTAssertEqual(object["netDrops"] as? Int, 2)
        XCTAssertEqual(object["pending"] as? Int, 1)
        XCTAssertEqual(object["inp50"] as? Double, 12)
        XCTAssertEqual(object["inp95"] as? Double, 34)
        XCTAssertEqual(object["capFps"] as? Int, 58)
    }

    func testExtraValueWithQuoteBackslashAndNewlineStaysValidJSON() throws {
        let hostile = "a\"b\\c\nd"
        let object = try parse(SenderControlJSON.ping(
            drops: 0, encDrops: 0, netDrops: 0, pending: 0,
            inp50: 0, inp95: 0, capFps: 0, extras: ["project": hostile]))
        XCTAssertEqual(object["project"] as? String, hostile)
    }

    func testExtrasAreEmittedInSortedKeyOrder() {
        let json = SenderControlJSON.ping(drops: 0, encDrops: 0, netDrops: 0, pending: 0,
                                          inp50: 0, inp95: 0, capFps: 0,
                                          extras: ["zulu": "z", "alpha": "a", "mike": "m"])
        // Sorted, and appended after the built-in fields: a Dictionary's own
        // order is randomized per process, so only sorting makes this hold.
        XCTAssertTrue(json.hasSuffix(",\"alpha\":\"a\",\"mike\":\"m\",\"zulu\":\"z\"}"), json)
    }

    func testExtraKeysCollidingWithBuiltInFieldsAreIgnored() throws {
        let json = SenderControlJSON.ping(drops: 7, encDrops: 5, netDrops: 2, pending: 1,
                                          inp50: 12, inp95: 34, capFps: 58,
                                          extras: ["type": "spoofed", "drops": "spoofed",
                                                   "channel": "attached"])
        XCTAssertEqual(json, SenderControlJSON.ping(drops: 7, encDrops: 5, netDrops: 2,
                                                    pending: 1, inp50: 12, inp95: 34,
                                                    capFps: 58,
                                                    extras: ["channel": "attached"]))
        let object = try parse(json)
        XCTAssertEqual(object["type"] as? String, "ping")
        XCTAssertEqual(object["drops"] as? Int, 7)
    }

    // MARK: - Helpers

    /// Verbatim copy of the interpolation `MacSender.schedulePing` used before
    /// `SenderControlJSON` existed, with the local names it read from.
    private func legacyPing(dropsTotal: Int, dropsEncTotal: Int, dropsNetTotal: Int,
                            pendingSends: Int, inp50: Double, inp95: Double,
                            capFps: Int) -> String {
        "{\"type\":\"ping\",\"drops\":\(dropsTotal),\"encDrops\":\(dropsEncTotal),\"netDrops\":\(dropsNetTotal),\"pending\":\(pendingSends),\"inp50\":\(inp50),\"inp95\":\(inp95),\"capFps\":\(capFps)}"
    }

    private func parse(_ json: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let dictionary = object as? [String: Any] else {
            XCTFail("not a JSON object: \(json)", file: file, line: line)
            return [:]
        }
        return dictionary
    }
}
