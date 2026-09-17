import XCTest
import Foundation

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine straight into
// it (see project.yml), so SSEParser and BackoffPolicy are available without
// an import.

final class SSEParserTests: XCTestCase {

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    func test_singleEvent_oneChunk() {
        var parser = SSEParser()
        let events = parser.feed(data("event: round.updated\ndata: hello\n\n"))
        XCTAssertEqual(events, [SSEEvent(event: "round.updated", data: "hello")])
    }

    func test_missingEventField_defaultsToMessage() {
        var parser = SSEParser()
        let events = parser.feed(data("data: hi\n\n"))
        XCTAssertEqual(events, [SSEEvent(event: "message", data: "hi")])
    }

    func test_eventSplitAcrossChunks() {
        var parser = SSEParser()
        let firstChunk = parser.feed(data("event: round.updated\ndata: hel"))
        XCTAssertEqual(firstChunk, [])

        let secondChunk = parser.feed(data("lo\n\n"))
        XCTAssertEqual(secondChunk, [SSEEvent(event: "round.updated", data: "hello")])
    }

    func test_eventSplitByteByByte() {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for byte in Array(data("event: round.updated\ndata: hi\n\n")) {
            events.append(contentsOf: parser.feed(Data([byte])))
        }
        XCTAssertEqual(events, [SSEEvent(event: "round.updated", data: "hi")])
    }

    func test_crlfLineEndings() {
        var parser = SSEParser()
        let events = parser.feed(data("event: round.updated\r\ndata: hi\r\n\r\n"))
        XCTAssertEqual(events, [SSEEvent(event: "round.updated", data: "hi")])
    }

    func test_multilineData_joinedWithNewline() {
        var parser = SSEParser()
        let events = parser.feed(data("data: line1\ndata: line2\n\n"))
        XCTAssertEqual(events, [SSEEvent(event: "message", data: "line1\nline2")])
    }

    func test_commentLines_areIgnored() {
        var parser = SSEParser()
        let events = parser.feed(data(": keep-alive comment\ndata: hi\n\n"))
        XCTAssertEqual(events, [SSEEvent(event: "message", data: "hi")])
    }

    func test_retryField_neverDispatchesOnItsOwn_andDoesNotLeakIntoTheNextEvent() {
        var parser = SSEParser()
        let events = parser.feed(data("retry: 1000\n\ndata: hi\n\n"))
        XCTAssertEqual(events, [SSEEvent(event: "message", data: "hi")])
    }

    func test_twoEventsInOneChunk() {
        var parser = SSEParser()
        let events = parser.feed(data("data: one\n\ndata: two\n\n"))
        XCTAssertEqual(events, [
            SSEEvent(event: "message", data: "one"),
            SSEEvent(event: "message", data: "two"),
        ])
    }
}

final class BackoffPolicyTests: XCTestCase {

    func test_sequence_doublesUpToMaximum() {
        var policy = BackoffPolicy()
        let sequence = (0..<6).map { _ in policy.next() }
        XCTAssertEqual(sequence, [0.5, 1, 2, 4, 5, 5])
    }

    func test_reset_returnsToMinimum() {
        var policy = BackoffPolicy()
        _ = policy.next()
        _ = policy.next()
        _ = policy.next()
        policy.reset()
        XCTAssertEqual(policy.next(), 0.5)
    }
}
