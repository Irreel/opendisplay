// Start drawing divides (Figma v3.2, M10, 2026-11-04): the drawing button
// stays where it is and turns into End drawing, while a drop of the same glass
// buds out of it toward the tool panel. The two are one outline: the waist
// between them is a smooth curve that thins to a thread and snaps, and the
// drop goes on at the speed it let go with, stretching into the panel's place
// and size. The panel takes over from it there, glass for glass. End drawing
// runs it home: the drop leaves the panel's place, a neck forms as it touches
// the button, and they fuse.
//
// While the drop is out it is the button's glass as well: the button draws
// only its symbol, over it. The screen drives it (`CanvasScreen.divide`) with
// one progress value on a linear clock each way; the curves are in here, so
// nothing stops and starts between steps. It is never touched or read out.

import SwiftUI

struct DividingCell: View, Animatable {

    /// 0 to 1 through the run: out to the panel when `entering`, home from
    /// it otherwise.
    var progress: CGFloat
    let entering: Bool
    /// The button and the panel at rest, in the chrome's space.
    let button: CGRect
    let panel: CGRect?

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// Out: the neck 0.5 s, then free 0.5 s. Home: free 0.35 s, then the
    /// neck 0.3 s.
    static let outDuration = 1.0
    static let homeDuration = 0.65

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .canvasGlass(in: Outline(path: outline))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // For the 56-point button, as the board draws it: the drop buds at 16
    // points round and is the button's size by 24 points out; the waist is
    // 44 points across by 40 out; the neck snaps at 100, centre to centre.
    private static let snap: CGFloat = 100

    private var outline: Path {
        let home = CGPoint(x: button.midX, y: button.midY)
        let r = button.width / 2
        let target = panel ?? button.offsetBy(dx: 160, dy: 0)
        let way = CGVector(dx: target.midX - home.x, dy: target.midY - home.y)
        let length = max(hypot(way.dx, way.dy), 1)
        let axis = CGVector(dx: way.dx / length, dy: way.dy / length)

        func round(_ d: CGFloat) -> CGRect {
            let size = d < 24 ? 16 + 12 * smoothstep(0, 24, d) : r
            let centre = CGPoint(x: home.x + axis.dx * d, y: home.y + axis.dy * d)
            return CGRect(x: centre.x - size, y: centre.y - size, width: 2 * size, height: 2 * size)
        }
        let snapped = round(Self.snap)
        let free = max(hypot(target.midX - snapped.midX, target.midY - snapped.midY), 1)

        // Out: distance as the square of time, so slow at first and quicker
        // as it stretches; once free it leaves at the speed the neck let go
        // with and settles into the panel. Home is the same, the other way.
        var distance: CGFloat?
        let drop: CGRect
        if entering {
            let t = progress * Self.outDuration
            if t < 0.5 {
                let u = t / 0.5
                distance = Self.snap * u * u
                drop = round(Self.snap * u * u)
            } else {
                let leaving = 2 * Self.snap / free
                drop = snapped.lerp(to: target, settle((t - 0.5) / 0.5, from: leaving))
            }
        } else {
            let t = progress * Self.homeDuration
            if t < 0.35 {
                let arriving = 2 * Self.snap / 0.3 * 0.35 / free
                drop = snapped.lerp(to: target, settle(1 - t / 0.35, from: arriving))
            } else {
                let u = (t - 0.35) / 0.3
                distance = Self.snap * (1 - u) * (1 - u)
                drop = round(Self.snap * (1 - u) * (1 - u))
            }
        }

        var path = Path()
        path.addCircle(home, radius: r)
        path.addRoundedRect(drop, radius: min(28, min(drop.width, drop.height) / 2))
        if let distance, let waist = Self.waist(distance, radius: r) {
            path.addPolygon(waist.map { CGPoint(x: home.x + axis.dx * $0.x - axis.dy * $0.y,
                                                 y: home.y + axis.dy * $0.x + axis.dx * $0.y) })
        }
        return path
    }

    /// The waist between the button and a drop its size, `distance` apart
    /// along the way (x) with the button at the origin: the straight span
    /// between the two pinch circles that touch both, less those circles. It
    /// thins from wider than where the two cross to nothing at the snap.
    static func waist(_ distance: CGFloat, radius r: CGFloat) -> [CGPoint]? {
        guard distance > 24, distance < snap else { return nil }
        let chord = { (d: CGFloat) in 2 * (max(r * r - d * d / 4, 0)).squareRoot() }
        let w = distance < 40
            ? chord(distance) + (44 - chord(40)) * (distance - 24) / 16
            : 44 * pow(1 - (distance - 40) / 60, 1.3)
        let h = distance / 2
        let pinch = (h * h + w * w / 4 - r * r) / (2 * r - w)
        guard pinch > 0.1 else { return nil }
        let y = pinch + w / 2, f = r / (r + pinch)
        let tx = h * f, ty = y * f
        let near = atan2(y - ty, tx - h), far = atan2(y - ty, distance - tx - h)
        func arc(_ centre: CGPoint, from a: CGFloat, to b: CGFloat) -> [CGPoint] {
            (0...16).map { i in
                let angle = a + (b - a) * CGFloat(i) / 16
                return CGPoint(x: centre.x + cos(angle) * pinch, y: centre.y + sin(angle) * pinch)
            }
        }
        // Along under the top pinch circle, across, back over the bottom one.
        return arc(CGPoint(x: h, y: -y), from: near, to: far)
            + arc(CGPoint(x: h, y: y), from: -far, to: -near)
    }
}

/// A path as a shape, for the glass.
private struct Outline: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}

// Every part is wound the same way (positive area in the chrome's y-down
// space), so where they overlap the non-zero fill unites them rather than
// cutting holes.
private extension Path {
    mutating func addArc(_ c: CGPoint, _ r: CGFloat, from a: CGFloat, to b: CGFloat) {
        let k = 4 / 3 * tan((b - a) / 4) * r
        let start = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
        let end = CGPoint(x: c.x + cos(b) * r, y: c.y + sin(b) * r)
        if currentPoint == nil { move(to: start) } else { addLine(to: start) }
        addCurve(to: end,
                 control1: CGPoint(x: start.x - k * sin(a), y: start.y + k * cos(a)),
                 control2: CGPoint(x: end.x + k * sin(b), y: end.y - k * cos(b)))
    }

    mutating func addCircle(_ c: CGPoint, radius r: CGFloat) {
        move(to: CGPoint(x: c.x + r, y: c.y))
        for i in 0..<4 {
            addArc(c, r, from: CGFloat(i) * .pi / 2, to: CGFloat(i + 1) * .pi / 2)
        }
        closeSubpath()
    }

    mutating func addRoundedRect(_ rect: CGRect, radius r: CGFloat) {
        move(to: CGPoint(x: rect.maxX, y: rect.minY + r))
        addArc(CGPoint(x: rect.maxX - r, y: rect.maxY - r), r, from: 0, to: .pi / 2)
        addArc(CGPoint(x: rect.minX + r, y: rect.maxY - r), r, from: .pi / 2, to: .pi)
        addArc(CGPoint(x: rect.minX + r, y: rect.minY + r), r, from: .pi, to: 1.5 * .pi)
        addArc(CGPoint(x: rect.maxX - r, y: rect.minY + r), r, from: 1.5 * .pi, to: 2 * .pi)
        closeSubpath()
    }

    mutating func addPolygon(_ points: [CGPoint]) {
        let area = zip(points, points.dropFirst() + [points[0]])
            .reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        addLines(area >= 0 ? points : points.reversed())
        closeSubpath()
    }
}

private extension CGRect {
    func lerp(to other: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: minX + (other.minX - minX) * t, y: minY + (other.minY - minY) * t,
               width: width + (other.width - width) * t, height: height + (other.height - height) * t)
    }
}

/// 0 to 1 over 0 to 1, leaving 0 at `speed` and arriving at rest.
private func settle(_ t: CGFloat, from speed: CGFloat) -> CGFloat {
    let t = min(max(t, 0), 1), speed = min(speed, 3)
    return speed * (t * t * t - 2 * t * t + t) + 3 * t * t - 2 * t * t * t
}

private func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Where the drawing button and the tool panel are laid out, in the chrome's
/// space, for `DividingCell`.
struct DrawingButtonFrameKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

struct ToolPanelFrameKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Reports this view's frame in the chrome's space under `key`.
    func chromeFrame<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGRect? {
        background(GeometryReader { geo in
            Color.clear.preference(key: key, value: geo.frame(in: .named("chrome")))
        })
    }
}
