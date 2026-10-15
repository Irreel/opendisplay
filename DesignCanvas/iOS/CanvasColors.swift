// The chrome's colours, as the design system's tokens name them. The system
// orange, red, blue and green are too light to read as text on the light
// glass (WCAG 1.4.3), so text in light appearance uses darker versions; dark
// appearance keeps the system colours, which already read on a dark surface.
// Small filled marks (dots, status circles) use the "strong" versions, which
// stay the same in both.

import SwiftUI
import UIKit

extension Color {
    /// Secondary text and glyphs: the secondary label at 78% instead of 60%.
    static let canvasSecondary = dynamic(light: UIColor(hex: 0x3C3C43, alpha: 0.78), dark: .secondaryLabel)

    static let canvasWarningText = dynamic(light: UIColor(hex: 0x9E4000), dark: .systemOrange)
    static let canvasDangerText = dynamic(light: UIColor(hex: 0xC30010), dark: .systemRed)
    static let canvasAccentText = dynamic(light: UIColor(hex: 0x0058BB), dark: .systemBlue)

    static let canvasWarningMark = Color(UIColor(hex: 0xC55300))
    static let canvasSuccessMark = Color(UIColor(hex: 0x248A3D))

    /// The fill laid over the glass, at 92%: opaque enough that the chrome's
    /// text reads over a dark mirror as well as a white page.
    static let canvasSurface = dynamic(light: UIColor(hex: 0xF5F5F5, alpha: 0.92),
                                       dark: UIColor(hex: 0x1C1C1E, alpha: 0.92))

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
