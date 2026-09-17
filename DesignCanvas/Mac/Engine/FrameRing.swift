import CoreVideo
import Foundation

/// A ring of clean, pre-encode frames keyed by ScreenCaptureKit capture
/// timestamp, so a Draw Mode freeze can look up the exact frame the iPad
/// froze on.
///
/// Not thread-safe: owned by one queue. Stores deep copies (see
/// `deepCopy(_:)`) so ScreenCaptureKit's buffer pool is never starved by
/// frames this ring is holding onto.
struct FrameRing {
    static let defaultCapacity = 16
    static let defaultToleranceMs: Int64 = 34

    private struct Entry {
        let pixelBuffer: CVPixelBuffer
        let captureMs: Int64
    }

    private let capacity: Int
    private var entries: [Entry] = []

    init(capacity: Int = FrameRing.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { entries.count }

    /// Deep-copies `pixelBuffer` and stores it under `captureMs`, evicting
    /// the oldest entry once `capacity` is exceeded. Silently drops the
    /// frame if the copy fails (an unsupported pixel format, or allocation
    /// failure) rather than storing a buffer that could alias the source.
    mutating func append(_ pixelBuffer: CVPixelBuffer, captureMs: Int64) {
        guard let copy = FrameRing.deepCopy(pixelBuffer) else { return }
        entries.append(Entry(pixelBuffer: copy, captureMs: captureMs))
        while entries.count > capacity {
            entries.removeFirst()
        }
    }

    /// The entry whose `captureMs` is closest to `captureMs`. An exact match
    /// always wins (its delta of 0 is the smallest possible). Ties pick the
    /// older frame, which falls out naturally here because `entries` is
    /// oldest-first and only a strictly smaller delta replaces the current
    /// best. Returns nil when the closest entry is still farther than
    /// `toleranceMs`, or the ring is empty.
    func frame(at captureMs: Int64, toleranceMs: Int64 = FrameRing.defaultToleranceMs) -> (pixelBuffer: CVPixelBuffer, captureMs: Int64)? {
        var best: Entry?
        var bestDelta: Int64 = .max
        for entry in entries {
            let delta = abs(entry.captureMs - captureMs)
            if delta < bestDelta {
                bestDelta = delta
                best = entry
            }
        }
        guard let best, bestDelta <= toleranceMs else { return nil }
        return (best.pixelBuffer, best.captureMs)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// Deep-copies a `kCVPixelFormatType_32BGRA` or
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` buffer (what
    /// ScreenCaptureKit delivers in this app) plane by plane, row by row,
    /// honouring each buffer's own bytes-per-row (source and destination
    /// strides can differ). The destination is created with
    /// `kCVPixelBufferIOSurfacePropertiesKey` so VideoToolbox can read it
    /// back out (see `Compositor.cgImage(from:)`). Returns nil for any other
    /// pixel format, or if allocation fails.
    static func deepCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        guard pixelFormat == kCVPixelFormatType_32BGRA
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }

        var destination: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &destination)
        guard status == kCVReturnSuccess, let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        if CVPixelBufferIsPlanar(source) {
            let planeCount = CVPixelBufferGetPlaneCount(source)
            for plane in 0..<planeCount {
                guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dstBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return nil }
                let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(source, plane)
                let copyBytes = min(srcBytesPerRow, dstBytesPerRow)
                for row in 0..<planeHeight {
                    memcpy(dstBase.advanced(by: row * dstBytesPerRow), srcBase.advanced(by: row * srcBytesPerRow), copyBytes)
                }
            }
        } else {
            guard let srcBase = CVPixelBufferGetBaseAddress(source),
                  let dstBase = CVPixelBufferGetBaseAddress(destination) else { return nil }
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
            let copyBytes = min(srcBytesPerRow, dstBytesPerRow)
            for row in 0..<height {
                memcpy(dstBase.advanced(by: row * dstBytesPerRow), srcBase.advanced(by: row * srcBytesPerRow), copyBytes)
            }
        }

        return destination
    }
}
