import CoreVideo
import Foundation

/// The clean, pre-encode frames recently sent to any iPad, keyed by frame
/// number, so a Draw Mode freeze can find the exact frame the iPad froze on.
///
/// Only frames handed to an encoder are kept: those are the only ones an iPad
/// can be looking at. One ring for the whole Mac, because every iPad mirrors
/// the same screen. Not thread-safe: `CleanFrameStore` wraps it in a lock.
/// Stores deep copies (see `deepCopy(_:)`) so ScreenCaptureKit's buffer pool
/// is never starved by frames this ring is holding onto.
/// A clean frame as the ring keeps it.
struct CleanFrame {
    let pixelBuffer: CVPixelBuffer
    /// When it was captured: what the daemon records as the capture's time.
    let capturedAt: Date
}

struct FrameRing {
    static let defaultCapacity = 16

    private struct Entry {
        let pixelBuffer: CVPixelBuffer
        let frame: UInt64
        let capturedAt: Date
    }

    private let capacity: Int
    private var entries: [Entry] = []

    init(capacity: Int = FrameRing.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { entries.count }

    func contains(_ frame: UInt64) -> Bool {
        entries.contains { $0.frame == frame }
    }

    /// Deep-copies `pixelBuffer` and stores it under `frame`, evicting the
    /// oldest entry once `capacity` is exceeded. A frame already held is not
    /// copied again: several iPads encode the same capture. Silently drops
    /// the frame if the copy fails (an unsupported pixel format, or
    /// allocation failure) rather than storing a buffer that could alias the
    /// source.
    mutating func append(_ pixelBuffer: CVPixelBuffer, frame: UInt64, capturedAt: Date) {
        guard !contains(frame), let copy = FrameRing.deepCopy(pixelBuffer) else { return }
        appendCopied(copy, frame: frame, capturedAt: capturedAt)
    }

    /// Stores a buffer that is already a private copy.
    mutating func appendCopied(_ copy: CVPixelBuffer, frame: UInt64, capturedAt: Date) {
        guard !contains(frame) else { return }
        entries.append(Entry(pixelBuffer: copy, frame: frame, capturedAt: capturedAt))
        while entries.count > capacity {
            entries.removeFirst()
        }
    }

    /// The frame stored under exactly this number, or nil when it was never
    /// stored or has been evicted.
    func frame(_ frame: UInt64) -> CleanFrame? {
        entries.last { $0.frame == frame }.map { CleanFrame(pixelBuffer: $0.pixelBuffer, capturedAt: $0.capturedAt) }
    }

    /// Allocates a fresh buffer of the same size and pixel format and copies
    /// every plane row by row (strides can differ between the two buffers).
    static func deepCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var copy: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                  attributes as CFDictionary, &copy) == kCVReturnSuccess,
              let copy else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        if CVPixelBufferIsPlanar(source) {
            let planes = CVPixelBufferGetPlaneCount(source)
            guard planes == CVPixelBufferGetPlaneCount(copy) else { return nil }
            for plane in 0..<planes {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { return nil }
                copyRows(from: src, srcStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                         to: dst, dstStride: CVPixelBufferGetBytesPerRowOfPlane(copy, plane),
                         rows: CVPixelBufferGetHeightOfPlane(source, plane))
            }
        } else {
            guard let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(copy) else { return nil }
            copyRows(from: src, srcStride: CVPixelBufferGetBytesPerRow(source),
                     to: dst, dstStride: CVPixelBufferGetBytesPerRow(copy), rows: height)
        }
        return copy
    }

    private static func copyRows(from src: UnsafeMutableRawPointer, srcStride: Int,
                                 to dst: UnsafeMutableRawPointer, dstStride: Int, rows: Int) {
        let rowBytes = min(srcStride, dstStride)
        if srcStride == dstStride {
            memcpy(dst, src, srcStride * rows)
            return
        }
        for row in 0..<rows {
            memcpy(dst + row * dstStride, src + row * srcStride, rowBytes)
        }
    }
}

/// What a canvas session needs from the capture: the clean frame an iPad
/// froze on.
protocol CleanFrameSource: AnyObject {
    func cleanFrame(_ frame: UInt64) -> CleanFrame?
}

/// The ring, shared by the links that fill it and the sessions that read it.
/// Thread-safe; the lock is never held across anything but the ring itself.
final class CleanFrameStore: CleanFrameSource {
    private let lock = NSLock()
    private var ring: FrameRing

    init(capacity: Int = FrameRing.defaultCapacity) {
        ring = FrameRing(capacity: capacity)
    }

    func keep(_ pixelBuffer: CVPixelBuffer, frame: UInt64, capturedAt: Date) {
        lock.lock()
        let known = ring.contains(frame)
        lock.unlock()
        guard !known else { return }
        // The copy happens outside the lock; only the insert is inside it.
        guard let copy = FrameRing.deepCopy(pixelBuffer) else { return }
        lock.lock()
        ring.appendCopied(copy, frame: frame, capturedAt: capturedAt)
        lock.unlock()
    }

    func cleanFrame(_ frame: UInt64) -> CleanFrame? {
        lock.lock()
        defer { lock.unlock() }
        return ring.frame(frame)
    }
}
