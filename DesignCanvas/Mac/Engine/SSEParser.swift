import Foundation

/// One dispatched Server-Sent Event: an `event:` name (defaulting to
/// `"message"` when the field is absent) and its `data:` payload.
struct SSEEvent: Equatable {
    let event: String
    let data: String
}

/// Parses a Server-Sent Events byte stream per the WHATWG field-parsing rules
/// (https://html.spec.whatwg.org/multipage/server-sent-events.html), minus
/// `id`/reconnection-time support, which the daemon's rounds stream never
/// uses. Line endings may be LF or CRLF. Bytes are buffered across `feed`
/// calls so an event split across network chunks (or across a single byte,
/// as `URLSession.bytes(for:)` delivers them) still parses correctly once the
/// rest arrives.
///
/// Line splitting happens on raw bytes, not decoded text: `\n` (0x0A) and
/// `\r` (0x0D) never appear as part of a multi-byte UTF-8 sequence (those use
/// only bytes >= 0x80), so scanning for them byte-by-byte is safe even if a
/// multi-byte character straddles a `feed` boundary elsewhere in the line.
struct SSEParser {
    private var pendingBytes = Data()
    private var eventType = ""
    private var dataLines: [String] = []

    mutating func feed(_ chunk: Data) -> [SSEEvent] {
        pendingBytes.append(chunk)
        var events: [SSEEvent] = []

        while let newline = pendingBytes.firstIndex(of: 0x0A) {
            var lineEnd = newline
            if lineEnd > pendingBytes.startIndex {
                let previous = pendingBytes.index(before: lineEnd)
                if pendingBytes[previous] == 0x0D {
                    lineEnd = previous
                }
            }
            let line = String(decoding: pendingBytes[pendingBytes.startIndex..<lineEnd], as: UTF8.self)
            pendingBytes.removeSubrange(pendingBytes.startIndex...newline)

            if let event = process(line: line) {
                events.append(event)
            }
        }

        return events
    }

    /// Applies one field line. A blank line dispatches the accumulated event
    /// (and is otherwise a no-op when no `data:` field has been seen, per
    /// spec — a lone `retry:` or `event:` block never fires anything).
    private mutating func process(line: String) -> SSEEvent? {
        if line.isEmpty {
            guard !dataLines.isEmpty else {
                eventType = ""
                return nil
            }
            let event = SSEEvent(event: eventType.isEmpty ? "message" : eventType, data: dataLines.joined(separator: "\n"))
            eventType = ""
            dataLines = []
            return event
        }

        if line.hasPrefix(":") {
            return nil // comment line: ignored entirely
        }

        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            var rawValue = String(line[line.index(after: colon)...])
            if rawValue.hasPrefix(" ") {
                rawValue.removeFirst()
            }
            value = rawValue
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            eventType = value
        case "data":
            dataLines.append(value)
        default:
            break // id/retry/unknown fields are ignored
        }
        return nil
    }
}

/// Exponential backoff for reconnect loops: doubles from `minimum` up to
/// `maximum` on each call, resetting back to `minimum` after `reset()`.
struct BackoffPolicy: Equatable {
    var minimum: TimeInterval = 0.5
    var maximum: TimeInterval = 5
    private var current: TimeInterval?

    mutating func next() -> TimeInterval {
        let value = min(current.map { $0 * 2 } ?? minimum, maximum)
        current = value
        return value
    }

    mutating func reset() {
        current = nil
    }
}
