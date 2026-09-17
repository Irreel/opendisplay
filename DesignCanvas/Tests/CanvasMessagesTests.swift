import XCTest
import Foundation

// NOTE: this hostless bundle compiles DesignCanvas/Shared straight into it
// (see project.yml), so these types are available without an import.

final class CanvasMessagesTests: XCTestCase {

    // MARK: - CanvasWire constants (spot check the exact values later tasks depend on)

    func test_canvasWireConstants() {
        XCTAssertEqual(CanvasWire.freeze, "freeze")
        XCTAssertEqual(CanvasWire.frozen, "frozen")
        XCTAssertEqual(CanvasWire.annotation, "annotation")
        XCTAssertEqual(CanvasWire.agentReply, "agentReply")
        XCTAssertEqual(CanvasWire.rounds, "rounds")
        XCTAssertEqual(CanvasWire.welcomeCanvasKey, "canvas")
        XCTAssertEqual(CanvasWire.pingChannelKey, "channel")
        XCTAssertEqual(CanvasWire.pingProjectKey, "project")
        XCTAssertEqual(CanvasWire.senderJSONLimit, 32768)
        XCTAssertEqual(CanvasWire.replyMessageMaxBytes, 2048)
        XCTAssertEqual(CanvasWire.roundsSnapshotLimit, 20)
        XCTAssertEqual(CanvasWire.shrunkTextMaxBytes, 256)
    }

    func test_roundStatus_rawValues() {
        XCTAssertEqual(RoundStatus.queued.rawValue, "queued")
        XCTAssertEqual(RoundStatus.sent.rawValue, "sent")
        XCTAssertEqual(RoundStatus.applied.rawValue, "applied")
        XCTAssertEqual(RoundStatus.failed.rawValue, "failed")
        XCTAssertEqual(RoundStatus.needsInput.rawValue, "needs_input")
    }

    func test_channelState_rawValues() {
        XCTAssertEqual(ChannelState.attached.rawValue, "attached")
        XCTAssertEqual(ChannelState.detached.rawValue, "detached")
        XCTAssertEqual(ChannelState.none.rawValue, "none")
    }

    // MARK: - NormalizedRect

    func test_normalizedRect_roundTrips() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        guard let decoded = NormalizedRect(json: rect.json) else {
            return XCTFail("expected decode to succeed")
        }
        XCTAssertEqual(decoded, rect)
    }

    func test_normalizedRect_nilOnMissingField() {
        XCTAssertNil(NormalizedRect(json: ["x": 0.1, "y": 0.2, "w": 0.3] as [String: Any]))
    }

    func test_normalizedRect_nilOnMistypedField() {
        XCTAssertNil(NormalizedRect(json: ["x": "0.1", "y": 0.2, "w": 0.3, "h": 0.4] as [String: Any]))
    }

    func test_normalizedRect_nilOnNonDictOrNil() {
        XCTAssertNil(NormalizedRect(json: nil))
        XCTAssertNil(NormalizedRect(json: "not a dict"))
    }

    func test_normalizedRect_ignoresUnknownExtraFields() {
        let json: [String: Any] = ["x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0, "extra": "ignored"]
        XCTAssertEqual(NormalizedRect(json: json), NormalizedRect.full)
    }

    func test_normalizedRect_numbersAsIntOrDoubleBothDecode() {
        // As real wire bytes would arrive: JSONSerialization boxes every JSON
        // number as NSNumber, whether the literal was written as an integer
        // or with a fractional part.
        let intJSON = try! JSONSerialization.jsonObject(with: Data(#"{"x":0,"y":0,"w":1,"h":1}"#.utf8)) as! [String: Any]
        let doubleJSON = try! JSONSerialization.jsonObject(with: Data(#"{"x":0.0,"y":0.0,"w":1.0,"h":1.0}"#.utf8)) as! [String: Any]
        XCTAssertEqual(NormalizedRect(json: intJSON), NormalizedRect.full)
        XCTAssertEqual(NormalizedRect(json: doubleJSON), NormalizedRect.full)
    }

    func test_normalizedRect_isFull() {
        XCTAssertTrue(NormalizedRect.full.isFull)
        XCTAssertTrue(NormalizedRect(x: 0.0005, y: -0.0005, width: 0.9996, height: 1.0).isFull)
        XCTAssertFalse(NormalizedRect(x: 0.01, y: 0, width: 1, height: 1).isFull)
        XCTAssertFalse(NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5).isFull)
    }

    func test_normalizedRect_clamped_negativeOrigin() {
        let clamped = NormalizedRect(x: -0.5, y: -0.5, width: 0.2, height: 0.2).clamped()
        XCTAssertEqual(clamped.x, 0, accuracy: 0.0001)
        XCTAssertEqual(clamped.y, 0, accuracy: 0.0001)
    }

    func test_normalizedRect_clamped_overflowPastOne() {
        let clamped = NormalizedRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5).clamped()
        XCTAssertLessThanOrEqual(clamped.x + clamped.width, 1.0001)
        XCTAssertLessThanOrEqual(clamped.y + clamped.height, 1.0001)
        XCTAssertGreaterThanOrEqual(clamped.x, 0)
        XCTAssertGreaterThanOrEqual(clamped.y, 0)
    }

    func test_normalizedRect_clamped_zeroSize() {
        let clamped = NormalizedRect(x: 0.5, y: 0.5, width: 0, height: 0).clamped()
        XCTAssertGreaterThanOrEqual(clamped.width, 0.01)
        XCTAssertGreaterThanOrEqual(clamped.height, 0.01)
    }

    func test_normalizedRect_clamped_negativeSize() {
        let clamped = NormalizedRect(x: 0.5, y: 0.5, width: -0.3, height: -0.9).clamped()
        XCTAssertGreaterThanOrEqual(clamped.width, 0.01)
        XCTAssertGreaterThanOrEqual(clamped.height, 0.01)
    }

    func test_normalizedRect_clamped_neverEmpty() {
        for rect in [
            NormalizedRect(x: 5, y: 5, width: 0, height: 0),
            NormalizedRect(x: -5, y: -5, width: -1, height: -1),
            NormalizedRect(x: 0, y: 0, width: 10, height: 10),
        ] {
            let clamped = rect.clamped()
            XCTAssertGreaterThan(clamped.width, 0)
            XCTAssertGreaterThan(clamped.height, 0)
        }
    }

    // MARK: - CanvasViewport

    func test_canvasViewport_roundTrips() {
        let viewport = CanvasViewport(width: 1024, height: 768, scale: 2.0)
        guard let decoded = CanvasViewport(json: viewport.json) else {
            return XCTFail("expected decode to succeed")
        }
        XCTAssertEqual(decoded, viewport)
    }

    func test_canvasViewport_nilOnMissingField() {
        XCTAssertNil(CanvasViewport(json: ["w": 1024, "h": 768] as [String: Any]))
    }

    func test_canvasViewport_nilOnMistypedField() {
        XCTAssertNil(CanvasViewport(json: ["w": "1024", "h": 768, "scale": 2.0] as [String: Any]))
    }

    func test_canvasViewport_nilOnNonDictOrNil() {
        XCTAssertNil(CanvasViewport(json: nil))
        XCTAssertNil(CanvasViewport(json: 42))
    }

    func test_canvasViewport_numbersAsIntOrDoubleBothDecode() {
        let intJSON = try! JSONSerialization.jsonObject(with: Data(#"{"w":1024,"h":768,"scale":2}"#.utf8)) as! [String: Any]
        let doubleJSON = try! JSONSerialization.jsonObject(with: Data(#"{"w":1024.0,"h":768.0,"scale":2.0}"#.utf8)) as! [String: Any]
        XCTAssertEqual(CanvasViewport(json: intJSON), CanvasViewport(width: 1024, height: 768, scale: 2.0))
        XCTAssertEqual(CanvasViewport(json: doubleJSON), CanvasViewport(width: 1024, height: 768, scale: 2.0))
    }

    // MARK: - FreezeMessage

    private let sampleRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)

    func test_freezeMessage_roundTrips() {
        let message = FreezeMessage(captureMs: 123_456_789, zoomRect: sampleRect, t: 42.5)
        guard let decoded = FreezeMessage(json: message.json) else {
            return XCTFail("expected decode to succeed")
        }
        XCTAssertEqual(decoded, message)
    }

    func test_freezeMessage_nilOnMissingCaptureMs() {
        var json = FreezeMessage(captureMs: 1, zoomRect: sampleRect, t: 1).json
        json.removeValue(forKey: "captureMs")
        XCTAssertNil(FreezeMessage(json: json))
    }

    func test_freezeMessage_nilOnMistypedCaptureMs() {
        var json = FreezeMessage(captureMs: 1, zoomRect: sampleRect, t: 1).json
        json["captureMs"] = "not-a-number"
        XCTAssertNil(FreezeMessage(json: json))
    }

    func test_freezeMessage_nilOnMissingZoomRect() {
        var json = FreezeMessage(captureMs: 1, zoomRect: sampleRect, t: 1).json
        json.removeValue(forKey: "zoomRect")
        XCTAssertNil(FreezeMessage(json: json))
    }

    func test_freezeMessage_nilOnMissingT() {
        var json = FreezeMessage(captureMs: 1, zoomRect: sampleRect, t: 1).json
        json.removeValue(forKey: "t")
        XCTAssertNil(FreezeMessage(json: json))
    }

    func test_freezeMessage_ignoresUnknownExtraFields() {
        var json = FreezeMessage(captureMs: 1, zoomRect: sampleRect, t: 1).json
        json["unexpected"] = "ignored"
        XCTAssertNotNil(FreezeMessage(json: json))
    }

    func test_freezeMessage_numbersAsIntOrDoubleBothDecode() {
        let intJSON = try! JSONSerialization.jsonObject(with: Data(#"{"captureMs":1000,"t":5,"zoomRect":{"x":0,"y":0,"w":1,"h":1}}"#.utf8)) as! [String: Any]
        let doubleJSON = try! JSONSerialization.jsonObject(with: Data(#"{"captureMs":1000.0,"t":5.0,"zoomRect":{"x":0,"y":0,"w":1,"h":1}}"#.utf8)) as! [String: Any]
        XCTAssertEqual(FreezeMessage(json: intJSON)?.captureMs, 1000)
        XCTAssertEqual(FreezeMessage(json: doubleJSON)?.captureMs, 1000)
        XCTAssertEqual(FreezeMessage(json: intJSON)?.t, 5)
        XCTAssertEqual(FreezeMessage(json: doubleJSON)?.t, 5)
    }

    // MARK: - FrozenMessage

    func test_frozenMessage_roundTrips() {
        for ok in [true, false] {
            let message = FrozenMessage(ok: ok)
            guard let decoded = FrozenMessage(json: message.json) else {
                return XCTFail("expected decode to succeed")
            }
            XCTAssertEqual(decoded, message)
        }
    }

    func test_frozenMessage_nilOnMissingOk() {
        XCTAssertNil(FrozenMessage(json: [:]))
    }

    func test_frozenMessage_nilOnMistypedOk() {
        XCTAssertNil(FrozenMessage(json: ["ok": "true"]))
    }

    // MARK: - AnnotationMessage

    private let sampleViewport = CanvasViewport(width: 800, height: 600, scale: 2.0)
    private let samplePNG = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes, arbitrary payload

    func test_annotationMessage_roundTrips_withNote() {
        let message = AnnotationMessage(sketchPNG: samplePNG, zoomRect: sampleRect, viewport: sampleViewport, note: "hello", t: 1.5)
        guard let decoded = AnnotationMessage(json: message.json) else {
            return XCTFail("expected decode to succeed")
        }
        XCTAssertEqual(decoded, message)
    }

    func test_annotationMessage_roundTrips_withoutNote() {
        let message = AnnotationMessage(sketchPNG: samplePNG, zoomRect: sampleRect, viewport: sampleViewport, note: nil, t: 1.5)
        guard let decoded = AnnotationMessage(json: message.json) else {
            return XCTFail("expected decode to succeed")
        }
        XCTAssertEqual(decoded, message)
        XCTAssertNil((message.json["note"]))
    }

    func test_annotationMessage_nilOnMissingSketch() {
        var json = AnnotationMessage(sketchPNG: samplePNG, zoomRect: sampleRect, viewport: sampleViewport, note: nil, t: 1).json
        json.removeValue(forKey: "sketch")
        XCTAssertNil(AnnotationMessage(json: json))
    }

    func test_annotationMessage_nilOnInvalidBase64() {
        var json = AnnotationMessage(sketchPNG: samplePNG, zoomRect: sampleRect, viewport: sampleViewport, note: nil, t: 1).json
        json["sketch"] = "!!!not-valid-base64!!!"
        XCTAssertNil(AnnotationMessage(json: json))
    }

    func test_annotationMessage_nilOnMissingZoomRect() {
        var json = AnnotationMessage(sketchPNG: samplePNG, zoomRect: sampleRect, viewport: sampleViewport, note: nil, t: 1).json
        json.removeValue(forKey: "zoomRect")
        XCTAssertNil(AnnotationMessage(json: json))
    }

    func test_annotationMessage_nilOnMissingViewport() {
        var json = AnnotationMessage(sketchPNG: samplePNG, zoomRect: sampleRect, viewport: sampleViewport, note: nil, t: 1).json
        json.removeValue(forKey: "viewport")
        XCTAssertNil(AnnotationMessage(json: json))
    }

    func test_annotationMessage_ignoresUnknownExtraFields() {
        var json = AnnotationMessage(sketchPNG: samplePNG, zoomRect: sampleRect, viewport: sampleViewport, note: nil, t: 1).json
        json["unexpected"] = 12345
        XCTAssertNotNil(AnnotationMessage(json: json))
    }

    // MARK: - AgentReplyMessage

    func test_agentReplyMessage_roundTrips_withOptionalFields() {
        let message = AgentReplyMessage(annotationId: "abc-123", status: .applied, message: "done", prUrl: "https://example.com/pr/1", t: 9.5)
        guard let decoded = AgentReplyMessage(json: message.json) else {
            return XCTFail("expected decode to succeed")
        }
        XCTAssertEqual(decoded, message)
    }

    func test_agentReplyMessage_roundTrips_withoutOptionalFields() {
        let message = AgentReplyMessage(annotationId: "abc-123", status: .sent, message: nil, prUrl: nil, t: 9.5)
        guard let decoded = AgentReplyMessage(json: message.json) else {
            return XCTFail("expected decode to succeed")
        }
        XCTAssertEqual(decoded, message)
    }

    func test_agentReplyMessage_allStatusesRoundTrip() {
        for status: RoundStatus in [.queued, .sent, .applied, .failed, .needsInput] {
            let message = AgentReplyMessage(annotationId: "id", status: status, message: nil, prUrl: nil, t: 0)
            XCTAssertEqual(AgentReplyMessage(json: message.json)?.status, status)
        }
    }

    func test_agentReplyMessage_nilOnMissingAnnotationId() {
        var json = AgentReplyMessage(annotationId: "id", status: .applied, message: nil, prUrl: nil, t: 0).json
        json.removeValue(forKey: "annotationId")
        XCTAssertNil(AgentReplyMessage(json: json))
    }

    func test_agentReplyMessage_nilOnInvalidStatus() {
        var json = AgentReplyMessage(annotationId: "id", status: .applied, message: nil, prUrl: nil, t: 0).json
        json["status"] = "not-a-real-status"
        XCTAssertNil(AgentReplyMessage(json: json))
    }

    func test_agentReplyMessage_nilOnMissingT() {
        var json = AgentReplyMessage(annotationId: "id", status: .applied, message: nil, prUrl: nil, t: 0).json
        json.removeValue(forKey: "t")
        XCTAssertNil(AgentReplyMessage(json: json))
    }

    // MARK: - CanvasRound

    func test_canvasRound_roundTrips_withOptionalFields() {
        let round = CanvasRound(annotationId: "id-1", createdAt: "2026-09-16T00:00:00Z", status: .failed, message: "oops", prUrl: "https://x", note: "note text")
        guard let decoded = CanvasRound(json: round.json) else {
            return XCTFail("expected decode to succeed")
        }
        XCTAssertEqual(decoded, round)
    }

    func test_canvasRound_roundTrips_withoutOptionalFields() {
        let round = CanvasRound(annotationId: "id-1", createdAt: "2026-09-16T00:00:00Z", status: .queued, message: nil, prUrl: nil, note: nil)
        guard let decoded = CanvasRound(json: round.json) else {
            return XCTFail("expected decode to succeed")
        }
        XCTAssertEqual(decoded, round)
    }

    func test_canvasRound_nilOnMissingAnnotationId() {
        var json = CanvasRound(annotationId: "id", createdAt: "t", status: .queued, message: nil, prUrl: nil, note: nil).json
        json.removeValue(forKey: "annotationId")
        XCTAssertNil(CanvasRound(json: json))
    }

    func test_canvasRound_nilOnMissingCreatedAt() {
        var json = CanvasRound(annotationId: "id", createdAt: "t", status: .queued, message: nil, prUrl: nil, note: nil).json
        json.removeValue(forKey: "createdAt")
        XCTAssertNil(CanvasRound(json: json))
    }

    func test_canvasRound_nilOnInvalidStatus() {
        var json = CanvasRound(annotationId: "id", createdAt: "t", status: .queued, message: nil, prUrl: nil, note: nil).json
        json["status"] = "bogus"
        XCTAssertNil(CanvasRound(json: json))
    }

    // MARK: - RoundsMessage

    private func makeRound(_ index: Int, message: String? = nil, prUrl: String? = nil, note: String? = nil) -> CanvasRound {
        CanvasRound(annotationId: "id-\(index)", createdAt: "2026-09-16T00:00:0\(index % 10)Z", status: .sent, message: message, prUrl: prUrl, note: note)
    }

    func test_roundsMessage_roundTrips() {
        let message = RoundsMessage(rounds: [makeRound(0), makeRound(1, message: "hi", note: "n")])
        guard let decoded = RoundsMessage(json: message.json) else {
            return XCTFail("expected decode to succeed")
        }
        XCTAssertEqual(decoded, message)
    }

    func test_roundsMessage_nilOnMissingRoundsKey() {
        XCTAssertNil(RoundsMessage(json: [:]))
    }

    /// M6: one entry this build cannot read — a status added later, a field
    /// gone missing — used to cost the device its whole round history. Skipping
    /// it is the same rule PROTOCOL.md section 6 already applies to unknown
    /// types and fields.
    func test_roundsMessage_skipsAnInvalidElement_andKeepsTheRest() {
        let json: [String: Any] = ["rounds": [
            makeRound(0).json,
            ["bad": "round"],
            ["annotationId": "id-2", "createdAt": "t", "status": "invented_later"],
            makeRound(1, message: "hi").json,
        ]]
        let decoded = RoundsMessage(json: json)
        XCTAssertEqual(decoded?.rounds.map(\.annotationId), ["id-0", "id-1"])
        XCTAssertEqual(decoded?.rounds.last?.message, "hi")
    }

    func test_roundsMessage_stillNilWhenTheRoundsKeyIsNotAnArrayOfObjects() {
        XCTAssertNil(RoundsMessage(json: ["rounds": "nope"]))
        XCTAssertNil(RoundsMessage(json: ["rounds": 42]))
    }

    func test_roundsMessage_emptyListRoundTrips() {
        let message = RoundsMessage(rounds: [])
        XCTAssertEqual(RoundsMessage(json: message.json), message)
    }

    // MARK: - RoundsMessage.encoded — size-safe rounds snapshot encoding

    func test_encoded_smallListUnchangedAndParsesBackEqual() {
        let message = RoundsMessage(rounds: [makeRound(0, message: "short"), makeRound(1, note: "also short")])
        let data = message.encoded()
        XCTAssertLessThan(data.count, CanvasWire.senderJSONLimit)

        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let decoded = RoundsMessage(json: obj)
        XCTAssertEqual(decoded, message)
    }

    func test_encoded_longMessagesAreCutTo256BytesAndFitUnderLimit() {
        let longMessage = String(repeating: "a", count: 2048)
        let rounds = (0..<20).map { makeRound($0, message: longMessage) }
        let message = RoundsMessage(rounds: rounds)

        let data = message.encoded()
        XCTAssertLessThan(data.count, CanvasWire.senderJSONLimit)

        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let decoded = RoundsMessage(json: obj)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.rounds.count, 20)
        for round in decoded?.rounds ?? [] {
            XCTAssertEqual(round.message?.utf8.count, CanvasWire.shrunkTextMaxBytes)
        }
    }

    func test_encoded_hugeIdsAndUrlsDropOldestUntilItFits() {
        let hugeId = String(repeating: "i", count: 3000)
        let hugeUrl = String(repeating: "u", count: 3000)
        let rounds = (0..<20).map { index in
            CanvasRound(annotationId: "\(index)-\(hugeId)", createdAt: "2026-09-16T00:00:00Z", status: .sent, message: nil, prUrl: hugeUrl, note: nil)
        }
        let message = RoundsMessage(rounds: rounds)

        let data = message.encoded()
        XCTAssertLessThan(data.count, CanvasWire.senderJSONLimit)

        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let decoded = RoundsMessage(json: obj)
        XCTAssertNotNil(decoded)
        let survivingCount = decoded?.rounds.count ?? 0
        XCTAssertGreaterThan(survivingCount, 0)
        XCTAssertLessThan(survivingCount, 20)
        // Oldest (last elements, since rounds are newest-first) were dropped:
        // the survivors are exactly the newest prefix of the original list.
        XCTAssertEqual(decoded?.rounds, Array(rounds.prefix(survivingCount)))
    }

    func test_encoded_neverReturnsEmptyData_evenWhenNothingFits() {
        // Pathologically oversized single round: even one entry alone exceeds
        // the limit. The encoder must still return valid, non-nil data.
        let hugeId = String(repeating: "x", count: 100_000)
        let message = RoundsMessage(rounds: [CanvasRound(annotationId: hugeId, createdAt: "t", status: .sent, message: nil, prUrl: nil, note: nil)])
        let data = message.encoded()
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(data.first, UInt8(ascii: "{"))
    }

    func test_encoded_startsWithOpenBraceAndContainsNoNulByte() {
        let longMessage = String(repeating: "a", count: 2048)
        let rounds = (0..<20).map { makeRound($0, message: longMessage) }
        let data = RoundsMessage(rounds: rounds).encoded()
        XCTAssertEqual(data.first, UInt8(ascii: "{"))
        XCTAssertFalse(data.contains(0))
    }

    // MARK: - RoundStatus.progressRank (M5)

    func test_progressRank_ordersARoundsLifecycle() {
        XCTAssertLessThan(RoundStatus.queued.progressRank, RoundStatus.sent.progressRank)
        XCTAssertLessThan(RoundStatus.sent.progressRank, RoundStatus.applied.progressRank)
        // The three outcomes are one rank: which of them a round ends in is not
        // progress, so a reply may correct one with another.
        XCTAssertEqual(RoundStatus.applied.progressRank, RoundStatus.failed.progressRank)
        XCTAssertEqual(RoundStatus.applied.progressRank, RoundStatus.needsInput.progressRank)
    }

    // MARK: - CanvasLink (M4)

    /// `prUrl` is filled in by the model, from whatever it read while working,
    /// and lands in the iPad's replies list as a tappable link. Everything but
    /// http(s) is refused there as well as in the daemon and the channel.
    func test_openableURL_acceptsOnlyHttpAndHttps() {
        XCTAssertEqual(CanvasLink.openableURL("https://github.test/o/r/pull/7")?.absoluteString,
                       "https://github.test/o/r/pull/7")
        XCTAssertEqual(CanvasLink.openableURL("http://localhost:3000/pull/1")?.absoluteString,
                       "http://localhost:3000/pull/1")
        XCTAssertEqual(CanvasLink.openableURL("HTTPS://GitHub.test/x")?.absoluteString,
                       "HTTPS://GitHub.test/x", "the scheme is compared case-insensitively")
    }

    func test_openableURL_rejectsEverythingElse() {
        XCTAssertNil(CanvasLink.openableURL(nil))
        XCTAssertNil(CanvasLink.openableURL(""))
        XCTAssertNil(CanvasLink.openableURL("   "))
        XCTAssertNil(CanvasLink.openableURL("javascript:alert(1)"))
        XCTAssertNil(CanvasLink.openableURL("file:///etc/passwd"))
        XCTAssertNil(CanvasLink.openableURL("data:text/html,<script>x</script>"))
        XCTAssertNil(CanvasLink.openableURL("designcanvas://do-something"))
        XCTAssertNil(CanvasLink.openableURL("/just/a/path"))
        XCTAssertNil(CanvasLink.openableURL("https://"), "no host")
        XCTAssertNil(CanvasLink.openableURL("https://example.test/\(String(repeating: "p", count: 2_100))"),
                     "over the 2048-character limit")
    }

    func test_openablePRURL_readsTheRoundsPrUrl() {
        let round = CanvasRound(annotationId: "a1", createdAt: "t", status: .applied,
                                message: nil, prUrl: "https://github.test/o/r/pull/7", note: nil)
        XCTAssertEqual(round.openablePRURL?.absoluteString, "https://github.test/o/r/pull/7")

        let hostile = CanvasRound(annotationId: "a1", createdAt: "t", status: .applied,
                                  message: nil, prUrl: "javascript:alert(1)", note: nil)
        XCTAssertNil(hostile.openablePRURL)
    }

    // MARK: - String.truncatedUTF8

    func test_truncatedUTF8_ascii() {
        XCTAssertEqual("hello world".truncatedUTF8(maxBytes: 5), "hello")
    }

    func test_truncatedUTF8_multiByteCharacterStraddlingLimit() {
        // "hi" (2 bytes) + a 4-byte emoji. A maxBytes of 4 must not split the
        // emoji's bytes, so the whole emoji is dropped rather than corrupted.
        let s = "hi😀"
        XCTAssertEqual(s.truncatedUTF8(maxBytes: 4), "hi")
        // A maxBytes just under the full string's length still can't fit the emoji.
        XCTAssertEqual(s.truncatedUTF8(maxBytes: 5), "hi")
        // A maxBytes covering the full string keeps it intact.
        XCTAssertEqual(s.truncatedUTF8(maxBytes: 6), "hi😀")
    }

    func test_truncatedUTF8_maxBytesZero() {
        XCTAssertEqual("anything".truncatedUTF8(maxBytes: 0), "")
    }

    func test_truncatedUTF8_stringAlreadyShortEnough() {
        XCTAssertEqual("short".truncatedUTF8(maxBytes: 100), "short")
    }

    func test_truncatedUTF8_appendsNothing() {
        let truncated = "hello world".truncatedUTF8(maxBytes: 5)
        XCTAssertFalse(truncated.hasSuffix("…"))
        XCTAssertEqual(truncated.utf8.count, 5)
    }
}
