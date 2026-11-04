// Design Canvas's own log, on both platforms.
//
// Mac: ~/Library/Logs/DesignCanvas/designcanvas.log, next to the daemon's
// server.log. iPad: designcanvas.log in the app's Documents, which the
// connection screen can show and share. Each file is capped and rotated
// once, so a decoder failing every frame cannot fill a disk.
//
// A hostless test run writes nothing to disk: the bundle compiles this file,
// and test sessions used to bury real ones in the shared log.

import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "designcanvas.log", qos: .utility)

    static let maxBytes: UInt64 = 4 * 1024 * 1024

    static let fileURL: URL = {
        #if os(macOS)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DesignCanvas", isDirectory: true)
        #else
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return directory.appendingPathComponent("designcanvas.log")
    }()

    private static var rotatedURL: URL { fileURL.appendingPathExtension("1") }

    private static let isRunningTests = NSClassFromString("XCTestCase") != nil

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func info(_ message: String) {
        guard !isRunningTests else { return }
        NSLog("[designcanvas] %@", message)
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { append(Data(line.utf8)) }
    }

    /// The newest `maxBytes` of the log (rotated file first), read after every
    /// line already queued has landed. Completion on the main queue.
    static func tail(maxBytes: Int = 256 * 1024, completion: @escaping (String) -> Void) {
        queue.async {
            var data = (try? Data(contentsOf: rotatedURL)) ?? Data()
            data.append((try? Data(contentsOf: fileURL)) ?? Data())
            if data.count > maxBytes {
                data = data.suffix(maxBytes)
                // Start on a whole line.
                if let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// Opens and closes a handle per line, so a rotation never leaves a handle
    /// writing into the renamed file.
    private static func append(_ data: Data) {
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size > maxBytes {
            try? manager.removeItem(at: rotatedURL)
            try? manager.moveItem(at: fileURL, to: rotatedURL)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// At most one log line per `interval` for something that can happen every
/// frame, carrying how many were swallowed since the last one.
struct LogThrottle {
    let interval: TimeInterval
    private var lastLoggedAt: TimeInterval = -.infinity
    private var suppressed = 0

    init(interval: TimeInterval = 1) {
        self.interval = interval
    }

    /// Nil: stay quiet. Otherwise the number of occurrences swallowed before
    /// this one, for the line to mention.
    mutating func admit(now: TimeInterval) -> Int? {
        guard now - lastLoggedAt >= interval else {
            suppressed += 1
            return nil
        }
        lastLoggedAt = now
        defer { suppressed = 0 }
        return suppressed
    }
}
