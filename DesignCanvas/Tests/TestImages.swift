import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// NOTE: this hostless bundle compiles DesignCanvas/Mac/Engine straight into
// it (see project.yml), so FrameRing/Compositor are available without an
// import.

/// Test-only builders and readers for `CGImage`/`CVPixelBuffer` fixtures.
///
/// Coordinate convention: everything here is top-left origin (row 0 / y=0 is
/// the top of the image), matching `NormalizedRect` and how
/// `CGImage.cropping(to:)` addresses image-space rects. This was verified
/// empirically (not assumed): a `CGImage` built directly from raw bytes with
/// row 0 holding one color and row 1 another crops correctly with
/// `cropping(to: CGRect(x:0,y:0,...))` returning row 0, `VTCreateCGImageFromCVPixelBuffer`
/// preserves the pixel buffer's row order, and drawing a full-extent image
/// into a same either-size `CGContext` (`draw(_:in:)` filling the whole
/// destination) never flips row order either — so pixel sampling below needs
/// no manual flip.
enum TestImages {
    struct RGBA: Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var a: UInt8

        init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }
    }

    // MARK: - CGImage builders

    /// Builds an RGBA8 `CGImage` from a per-pixel callback, top-left origin.
    static func cgImage(width: Int, height: Int, hasAlpha: Bool = false, pixel: (Int, Int) -> RGBA) -> CGImage {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let offset = y * bytesPerRow + x * 4
                if hasAlpha {
                    let factor = Double(color.a) / 255.0
                    bytes[offset] = UInt8((Double(color.r) * factor).rounded())
                    bytes[offset + 1] = UInt8((Double(color.g) * factor).rounded())
                    bytes[offset + 2] = UInt8((Double(color.b) * factor).rounded())
                    bytes[offset + 3] = color.a
                } else {
                    bytes[offset] = color.r
                    bytes[offset + 1] = color.g
                    bytes[offset + 2] = color.b
                    bytes[offset + 3] = 255
                }
            }
        }
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    static func solidCGImage(width: Int, height: Int, color: RGBA, hasAlpha: Bool = false) -> CGImage {
        cgImage(width: width, height: height, hasAlpha: hasAlpha) { _, _ in color }
    }

    /// Left half `left`, right half `right` (column < width/2 is left).
    static func leftRightCGImage(width: Int, height: Int, left: RGBA, right: RGBA) -> CGImage {
        cgImage(width: width, height: height) { x, _ in x < width / 2 ? left : right }
    }

    /// Top half `top`, bottom half `bottom` (row < height/2 is top).
    static func topBottomCGImage(width: Int, height: Int, top: RGBA, bottom: RGBA) -> CGImage {
        cgImage(width: width, height: height) { _, y in y < height / 2 ? top : bottom }
    }

    /// An opaque `fill` rect (top-left origin, pixel-indexed) on an
    /// otherwise fully transparent image, for sketch PNG fixtures.
    static func rectOnTransparentCGImage(width: Int, height: Int, rect: CGRect, fill: RGBA) -> CGImage {
        cgImage(width: width, height: height, hasAlpha: true) { x, y in
            rect.contains(CGPoint(x: Double(x), y: Double(y))) ? fill : RGBA(0, 0, 0, 0)
        }
    }

    static func pngData(_ image: CGImage) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: - Pixel reading (CGImage / PNG)

    /// Decodes `data` as a PNG and samples one pixel, top-left origin.
    static func pixel(inPNG data: Data, x: Int, y: Int) -> RGBA? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return pixel(in: image, x: x, y: y)
    }

    /// Samples one pixel of `image`, top-left origin, by drawing into a
    /// fresh RGBA8 context and reading the raw buffer directly (sidesteps
    /// the source image's own bit layout/alpha format).
    static func pixel(in image: CGImage, x: Int, y: Int) -> RGBA? {
        guard x >= 0, x < image.width, y >= 0, y < image.height else { return nil }
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = y * bytesPerRow + x * 4
        let alpha = buffer[offset + 3]
        func unpremultiply(_ value: UInt8) -> UInt8 {
            guard alpha > 0 else { return 0 }
            let result = (Double(value) * 255.0 / Double(alpha)).rounded()
            return UInt8(min(255, max(0, result)))
        }
        return RGBA(unpremultiply(buffer[offset]), unpremultiply(buffer[offset + 1]), unpremultiply(buffer[offset + 2]), alpha)
    }

    // MARK: - CVPixelBuffer builders (what ScreenCaptureKit delivers)

    static func solidBGRAPixelBuffer(width: Int, height: Int, color: RGBA) -> CVPixelBuffer {
        let buffer = makePixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            let rowPtr = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for col in 0..<width {
                let pixelPtr = rowPtr.advanced(by: col * 4)
                pixelPtr[0] = color.b
                pixelPtr[1] = color.g
                pixelPtr[2] = color.r
                pixelPtr[3] = color.a
            }
        }
        return buffer
    }

    /// Only exact grays (r == g == b) round-trip faithfully through YUV:
    /// equal RGB always maps to neutral (achromatic) chroma regardless of
    /// which matrix the decoder assumes.
    static func solidNV12PixelBuffer(width: Int, height: Int, gray: UInt8) -> CVPixelBuffer {
        let buffer = makePixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let luma = UInt8((16.0 + 219.0 * Double(gray) / 255.0).rounded())
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let yWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        for row in 0..<yHeight {
            let rowPtr = yBase.advanced(by: row * yBytesPerRow).assumingMemoryBound(to: UInt8.self)
            for col in 0..<yWidth {
                rowPtr[col] = luma
            }
        }

        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        for row in 0..<chromaHeight {
            let rowPtr = chromaBase.advanced(by: row * chromaBytesPerRow).assumingMemoryBound(to: UInt8.self)
            for col in 0..<chromaWidth {
                rowPtr[col * 2] = 128     // Cb
                rowPtr[col * 2 + 1] = 128 // Cr
            }
        }
        return buffer
    }

    /// Reads one pixel of a BGRA buffer directly (no color conversion).
    static func pixel(inBGRA buffer: CVPixelBuffer, x: Int, y: Int) -> RGBA? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard x >= 0, x < CVPixelBufferGetWidth(buffer), y >= 0, y < CVPixelBufferGetHeight(buffer),
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixelPtr = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return RGBA(pixelPtr[2], pixelPtr[1], pixelPtr[0], pixelPtr[3])
    }

    /// Reads the luma sample of an NV12 buffer directly (no color
    /// conversion) — enough to detect whether a deep copy diverged from a
    /// mutated source.
    static func luma(inNV12 buffer: CVPixelBuffer, x: Int, y: Int) -> UInt8? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard x >= 0, x < CVPixelBufferGetWidthOfPlane(buffer, 0), y >= 0, y < CVPixelBufferGetHeightOfPlane(buffer, 0),
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        return base.advanced(by: y * bytesPerRow + x).assumingMemoryBound(to: UInt8.self).pointee
    }

    /// Overwrites one BGRA pixel in place (to test that a deep copy does not
    /// alias the source).
    static func setPixel(inBGRA buffer: CVPixelBuffer, x: Int, y: Int, color: RGBA) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixelPtr = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        pixelPtr[0] = color.b
        pixelPtr[1] = color.g
        pixelPtr[2] = color.r
        pixelPtr[3] = color.a
    }

    /// Overwrites the luma plane's first sample in place (to test that a
    /// deep copy does not alias the source).
    static func setLuma(inNV12 buffer: CVPixelBuffer, x: Int, y: Int, value: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        base.advanced(by: y * bytesPerRow + x).assumingMemoryBound(to: UInt8.self).pointee = value
    }

    private static func makePixelBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &pixelBuffer)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        return pixelBuffer!
    }
}
