import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

enum CompositorError: Error, Equatable {
    case undecodableSketch
    case emptyBase
    case encodeFailed
}

/// The image handed to Claude Code: the (optionally cropped, size-capped)
/// base frame with the iPad's sketch flattened over it.
struct CompositeResult {
    let compositePNG: Data
    let sketchPNG: Data
    let screenshotPNG: Data
    let compositeSize: CGSize
    /// Top-left-origin pixel coordinates of the base image.
    let cropRectPixels: CGRect
}

/// Crops a frame to the iPad's zoom region, flattens its sketch over it, and
/// caps the result's long side, all in CoreGraphics/ImageIO/VideoToolbox —
/// no UIKit/AppKit, so this stays testable in a hostless bundle.
enum Compositor {
    static let maxLongSide = 1568

    /// The color space every context this file creates is tagged with.
    /// `CGColorSpaceCreateDeviceRGB()` is device-dependent — its exact
    /// meaning isn't fixed by the type system, only by whatever the host
    /// happens to resolve it to — so an explicit, portable, well-defined
    /// space is used instead, per the plan's "CoreGraphics + ImageIO +
    /// VideoToolbox; sRGB" requirement.
    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Converts a ring frame back into a `CGImage` for `composite(base:...)`.
    /// Handles `kCVPixelFormatType_32BGRA` and
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`, what
    /// ScreenCaptureKit delivers in this app.
    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard status == noErr else { return nil }
        return image
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// `zoomRect` is clamped to the base's bounds (clipped, not
    /// repositioned: a rect that overlaps the edge is cut off there rather
    /// than shifted inward — see the crop-rounding note below).
    /// `zoomRect.isFull` means no crop. The sketch is stretched over the
    /// crop, and the result is scaled so its long side is at most
    /// `maxLongSide` (never upscaled). `screenshotPNG` is the full,
    /// uncropped base. An empty sketch (zero bytes) means "no strokes":
    /// composite == crop. Undecodable non-empty sketch bytes throw
    /// `.undecodableSketch`.
    ///
    /// Coordinates: `NormalizedRect` and `cropRectPixels` are both top-left
    /// origin, matching `CGImage.cropping(to:)`'s own image-space rect, so
    /// converting the zoom rect to pixels needs no flip (guarded by
    /// `test_zoomRect_topHalf_ofRedTopBlueBottom_givesAllRed_notFlipped`,
    /// which crops via `pixelCropRect`/`cropping(to:)` and would fail were
    /// that flipped). Flattening the sketch and scaling the result also need
    /// no flip: both only ever draw a `CGImage` into a `CGContext` at the
    /// context's *full* extent (`CGRect(x: 0, y: 0, width:, height:)`), and
    /// a full-extent `draw(_:in:)` preserves row order regardless of
    /// CoreGraphics's bottom-left-origin *drawing* space (verified
    /// empirically). `flatten`'s copy of this is guarded by
    /// `test_sketch_opaqueOverridesTransparentShowsBase` (a flipped flatten
    /// would draw the sketch rect at the mirrored row) and `scaledDown`'s by
    /// `test_scaledDown_preservesTopBottomOrder`.
    static func composite(base: CGImage, sketchPNG: Data, zoomRect: NormalizedRect) throws -> CompositeResult {
        guard base.width > 0, base.height > 0 else { throw CompositorError.emptyBase }

        let sketchImage: CGImage?
        if sketchPNG.isEmpty {
            sketchImage = nil
        } else {
            guard let source = CGImageSourceCreateWithData(sketchPNG as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CompositorError.undecodableSketch
            }
            sketchImage = decoded
        }

        guard let screenshotPNG = pngData(base) else { throw CompositorError.encodeFailed }

        let cropRectPixels = pixelCropRect(for: zoomRect, imageWidth: base.width, imageHeight: base.height)
        let croppedBase: CGImage
        if zoomRect.isFull {
            croppedBase = base
        } else {
            guard let cropped = base.cropping(to: cropRectPixels) else { throw CompositorError.emptyBase }
            croppedBase = cropped
        }

        let flattened: CGImage
        if let sketchImage {
            guard let composed = flatten(base: croppedBase, sketch: sketchImage) else {
                throw CompositorError.encodeFailed
            }
            flattened = composed
        } else {
            flattened = croppedBase
        }

        let scaled = scaledDown(flattened, maxLongSide: maxLongSide)

        guard let compositePNG = pngData(scaled) else { throw CompositorError.encodeFailed }

        return CompositeResult(
            compositePNG: compositePNG,
            sketchPNG: sketchPNG,
            screenshotPNG: screenshotPNG,
            compositeSize: CGSize(width: scaled.width, height: scaled.height),
            cropRectPixels: cropRectPixels
        )
    }

    // MARK: - Private

    /// Converts `zoomRect` (unit square, top-left origin) to whole-pixel,
    /// top-left-origin coordinates of an `imageWidth` x `imageHeight` image.
    /// Rounds outward to whole pixels, then clips to the image bounds (a
    /// rect that only partly overlaps loses the part outside — it is not
    /// shifted inward to preserve its requested size). Never returns a
    /// zero-sized rect.
    private static func pixelCropRect(for zoomRect: NormalizedRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        if zoomRect.isFull { return bounds }

        let width = zoomRect.width > 0 ? zoomRect.width : 0.01
        let height = zoomRect.height > 0 ? zoomRect.height : 0.01
        let raw = CGRect(
            x: zoomRect.x * Double(imageWidth),
            y: zoomRect.y * Double(imageHeight),
            width: width * Double(imageWidth),
            height: height * Double(imageHeight)
        )
        let rounded = CGRect(
            x: raw.minX.rounded(.down),
            y: raw.minY.rounded(.down),
            width: raw.maxX.rounded(.up) - raw.minX.rounded(.down),
            height: raw.maxY.rounded(.up) - raw.minY.rounded(.down)
        )

        var clipped = rounded.intersection(bounds)
        if clipped.isEmpty || clipped.width < 1 || clipped.height < 1 {
            // The requested rect landed entirely outside the image (or
            // rounded to nothing at an edge): pin a single-pixel rect to
            // the nearest valid position rather than return nothing.
            let x = min(max(rounded.minX, 0), Double(imageWidth) - 1)
            let y = min(max(rounded.minY, 0), Double(imageHeight) - 1)
            clipped = CGRect(x: x, y: y, width: 1, height: 1)
        }
        return clipped
    }

    /// Draws `base` then `sketch` (stretched to `base`'s size) into a fresh
    /// context and returns the flattened result.
    private static func flatten(base: CGImage, sketch: CGImage) -> CGImage? {
        let width = base.width
        let height = base.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: workingColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(base, in: rect)
        context.draw(sketch, in: rect)
        return context.makeImage()
    }

    /// Scales `image` down so its long side is at most `maxLongSide`,
    /// never upscaling. Returns `image` unchanged when no scaling is
    /// needed, to avoid a lossy re-render of the common case.
    private static func scaledDown(_ image: CGImage, maxLongSide: Int) -> CGImage {
        let width = image.width
        let height = image.height
        let longSide = max(width, height)
        let scale = min(1, Double(maxLongSide) / Double(longSide))
        guard scale < 1 else { return image }

        let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: workingColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        return context.makeImage() ?? image
    }
}
