import XCTest

// NOTE: this hostless bundle compiles `Shared/CanvasReceiverState.swift`
// straight into it (see project.yml), so the type is available without an
// import. The dictionaries under test are built by parsing wire JSON rather
// than by Swift literals: JSONSerialization is what boxes `true` as a
// CFBoolean and `"true"` as a String, and telling those apart is the point
// of the capability gate.

final class CanvasReceiverStateTests: XCTestCase {

    private func wire(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - welcome: the canvas capability gate

    func test_welcomeWithCanvasTrue_enablesCanvas() throws {
        var state = CanvasReceiverState()
        state.handleWelcome(try wire(#"{"type":"welcome","pv":3,"min":1,"canvas":true}"#))
        XCTAssertTrue(state.macSupportsCanvas)
    }

    func test_welcomeWithCanvasFalse_leavesCanvasOff() throws {
        var state = CanvasReceiverState()
        state.handleWelcome(try wire(#"{"type":"welcome","pv":3,"min":1,"canvas":false}"#))
        XCTAssertFalse(state.macSupportsCanvas)
    }

    func test_welcomeWithoutCanvasKey_leavesCanvasOff() throws {
        var state = CanvasReceiverState()
        state.handleWelcome(try wire(#"{"type":"welcome","pv":3,"min":1}"#))
        XCTAssertFalse(state.macSupportsCanvas)
    }

    func test_welcomeWithCanvasAsTheNumberOne_leavesCanvasOff() throws {
        var state = CanvasReceiverState()
        state.handleWelcome(try wire(#"{"type":"welcome","pv":3,"min":1,"canvas":1}"#))
        XCTAssertFalse(state.macSupportsCanvas,
                       "the gate is a JSON true, and JSONSerialization boxes 1 as the same NSNumber")
    }

    func test_welcomeWithCanvasAsString_leavesCanvasOff() throws {
        var state = CanvasReceiverState()
        state.handleWelcome(try wire(#"{"type":"welcome","pv":3,"min":1,"canvas":"true"}"#))
        XCTAssertFalse(state.macSupportsCanvas)
    }

    func test_welcomeWithoutCanvas_afterACanvasWelcome_turnsCanvasOff() throws {
        var state = CanvasReceiverState()
        state.handleWelcome(try wire(#"{"type":"welcome","canvas":true}"#))
        state.handleWelcome(try wire(#"{"type":"welcome"}"#))
        XCTAssertFalse(state.macSupportsCanvas)
    }

    // MARK: - ping: channel and project

    func test_pingSetsChannelAndProject() throws {
        var state = CanvasReceiverState()
        state.handlePing(try wire(#"{"type":"ping","channel":"attached","project":"site"}"#))
        XCTAssertEqual(state.channel, "attached")
        XCTAssertEqual(state.project, "site")
    }

    func test_pingWithoutProject_clearsProject() throws {
        var state = CanvasReceiverState()
        state.handlePing(try wire(#"{"type":"ping","channel":"attached","project":"site"}"#))
        state.handlePing(try wire(#"{"type":"ping","channel":"attached"}"#))
        XCTAssertEqual(state.channel, "attached")
        XCTAssertNil(state.project)
    }

    func test_pingWithoutChannel_keepsChannel() throws {
        var state = CanvasReceiverState()
        state.handlePing(try wire(#"{"type":"ping","channel":"detached","project":"site"}"#))
        state.handlePing(try wire(#"{"type":"ping","drops":0}"#))
        XCTAssertEqual(state.channel, "detached")
    }

    // MARK: - route: canvas messages are gated on the welcome

    func test_routeDeliversTheThreeCanvasTypes_afterACanvasWelcome() throws {
        var state = CanvasReceiverState()
        state.handleWelcome(try wire(#"{"type":"welcome","canvas":true}"#))
        XCTAssertEqual(state.route(type: "frozen"), .canvasMessage(type: "frozen"))
        XCTAssertEqual(state.route(type: "agentReply"), .canvasMessage(type: "agentReply"))
        XCTAssertEqual(state.route(type: "rounds"), .canvasMessage(type: "rounds"))
    }

    func test_routeIgnoresCanvasTypes_beforeAnyWelcome() {
        var state = CanvasReceiverState()
        XCTAssertEqual(state.route(type: "frozen"), .none)
        XCTAssertEqual(state.route(type: "agentReply"), .none)
        XCTAssertEqual(state.route(type: "rounds"), .none)
    }

    func test_routeIgnoresANonCanvasType_evenOnACanvasSession() throws {
        var state = CanvasReceiverState()
        state.handleWelcome(try wire(#"{"type":"welcome","canvas":true}"#))
        XCTAssertEqual(state.route(type: "cursor"), .none)
    }

    // MARK: - connectionReset

    func test_connectionResetClearsCanvasChannelProjectAndFrozen() throws {
        var state = CanvasReceiverState()
        state.handleWelcome(try wire(#"{"type":"welcome","canvas":true}"#))
        state.handlePing(try wire(#"{"type":"ping","channel":"attached","project":"site"}"#))
        _ = state.setFrozen(true)

        state.connectionReset()

        XCTAssertFalse(state.macSupportsCanvas)
        XCTAssertNil(state.channel)
        XCTAssertNil(state.project)
        XCTAssertFalse(state.frozen)
        XCTAssertFalse(state.shouldDropFrames)
    }

    func test_connectionResetKeepsTheInputSuppressionTheAppConfigured() {
        var state = CanvasReceiverState()
        state.suppressesInput = true
        state.connectionReset()
        XCTAssertTrue(state.suppressesInput)
    }

    // MARK: - freeze

    func test_setFrozenTrue_freezesWithoutAskingForAKeyframe() {
        var state = CanvasReceiverState()
        XCTAssertFalse(state.setFrozen(true))
        XCTAssertTrue(state.frozen)
        XCTAssertTrue(state.shouldDropFrames)
    }

    func test_setFrozenFalse_afterAFreeze_asksForAKeyframe() {
        var state = CanvasReceiverState()
        _ = state.setFrozen(true)
        XCTAssertTrue(state.setFrozen(false))
        XCTAssertFalse(state.frozen)
        XCTAssertFalse(state.shouldDropFrames)
    }

    func test_setFrozenIsIdempotent_soRepeatsAskForNothing() {
        var state = CanvasReceiverState()
        XCTAssertFalse(state.setFrozen(false))   // already thawed
        _ = state.setFrozen(true)
        XCTAssertFalse(state.setFrozen(true))    // already frozen
        _ = state.setFrozen(false)
        XCTAssertFalse(state.setFrozen(false))   // thawed again
    }

    // MARK: - input suppression

    func test_allowsInputSendFollowsSuppressesInput() {
        var state = CanvasReceiverState()
        XCTAssertTrue(state.allowsInputSend)
        state.suppressesInput = true
        XCTAssertFalse(state.allowsInputSend)
        state.suppressesInput = false
        XCTAssertTrue(state.allowsInputSend)
    }


    // MARK: - ping: the blank canvas capability

    func test_pingWithBlank_setsTheCapability() throws {
        var state = CanvasReceiverState()
        XCTAssertFalse(state.macSupportsBlank)
        state.handlePing(try wire(#"{"type":"ping","channel":"attached","blank":"1"}"#))
        XCTAssertTrue(state.macSupportsBlank)
    }

    func test_pingWithoutBlank_clearsTheCapability() throws {
        var state = CanvasReceiverState()
        state.handlePing(try wire(#"{"type":"ping","channel":"attached","blank":"1"}"#))
        state.handlePing(try wire(#"{"type":"ping","channel":"attached"}"#))
        XCTAssertFalse(state.macSupportsBlank)
    }

    func test_connectionResetClearsTheBlankCapability() throws {
        var state = CanvasReceiverState()
        state.handlePing(try wire(#"{"type":"ping","channel":"attached","blank":"1"}"#))
        state.connectionReset()
        XCTAssertFalse(state.macSupportsBlank)
    }
}
