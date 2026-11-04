// How big the mirror stream is, decided once per capture. Pure, so the
// arithmetic is tested without a display.

import Foundation

/// The capture/encode resolution and bitrate trade-off, set by the `quality`
/// default (`defaults write com.designcanvas.mac quality balanced`).
enum StreamQuality: String, CaseIterable {
    case best, balanced, fast

    var scale: Double {
        switch self {
        case .best: return 1.0
        case .balanced: return 0.75
        case .fast: return 0.5
        }
    }

    var bitrate: Int {
        switch self {
        case .best: return 20_000_000
        case .balanced: return 12_000_000
        case .fast: return 8_000_000
        }
    }

    static var stored: StreamQuality {
        UserDefaults.standard.string(forKey: "quality").flatMap(StreamQuality.init(rawValue:)) ?? .best
    }
}

enum StreamGeometry {
    /// H.264 level 5.2's largest frame, in 16×16 macroblocks (4096×2304). A
    /// bigger frame is rejected by the encoder frame after frame, which is
    /// what a 5K display at full size used to do.
    static let maxMacroblocks = 36_864
    /// The longest side the hardware encoders accept.
    static let maxSide = 4096

    /// The stream size for a display of `pixelWidth` × `pixelHeight` at
    /// `scale`: the display's aspect ratio kept, both sides even, and scaled
    /// down only as far as the encoder needs. Never smaller than 2×2.
    static func streamSize(pixelWidth: Int, pixelHeight: Int, scale: Double) -> (width: Int, height: Int) {
        guard pixelWidth > 0, pixelHeight > 0 else { return (2, 2) }
        let factor = scale.isFinite && scale > 0 ? min(scale, 1) : 1
        var w = Double(pixelWidth) * factor
        var h = Double(pixelHeight) * factor
        let fit = min(1,
                      Double(maxSide) / w,
                      Double(maxSide) / h,
                      (Double(maxMacroblocks) * 256 / (w * h)).squareRoot())
        w *= fit
        h *= fit
        var width = max(2, Int(w) & ~1)
        var height = max(2, Int(h) & ~1)
        // Macroblocks round up, so a size that fits by area can still be one
        // row over. Shrink in small steps, keeping the aspect ratio.
        while macroblocks(width, height) > maxMacroblocks {
            width = max(2, Int(Double(width) * 0.99) & ~1)
            height = max(2, Int(Double(height) * 0.99) & ~1)
        }
        return (width, height)
    }

    static func macroblocks(_ width: Int, _ height: Int) -> Int {
        ((width + 15) / 16) * ((height + 15) / 16)
    }
}
