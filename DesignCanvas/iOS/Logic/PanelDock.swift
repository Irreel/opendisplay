// Where the control panel sits. The panel — Mirror, Blank and Draw between
// sketches, the drawing tools in Draw Mode — is one object the designer can
// drag to any edge of the screen. It snaps to the middle of that edge and stays
// there across mode changes and launches; it never floats over the picture.
//
// CoreGraphics only: this is compiled into the hostless test bundle.

import CoreGraphics

enum PanelEdge: String, CaseIterable {
    case top, bottom, leading, trailing

    /// On a side edge the panel's controls run top to bottom.
    var isVertical: Bool { self == .leading || self == .trailing }

    /// Where the panel's centre rests on this edge, `inset` in from it.
    func restingCenter(in size: CGSize, inset: CGFloat) -> CGPoint {
        switch self {
        case .top: return CGPoint(x: size.width / 2, y: inset)
        case .bottom: return CGPoint(x: size.width / 2, y: size.height - inset)
        case .leading: return CGPoint(x: inset, y: size.height / 2)
        case .trailing: return CGPoint(x: size.width - inset, y: size.height / 2)
        }
    }

    /// The edge a panel dropped at `point` snaps to: the closest one. A tie
    /// goes to the earlier case, so the dead centre of the screen is the top.
    static func nearest(to point: CGPoint, in size: CGSize) -> PanelEdge {
        guard size.width > 0, size.height > 0 else { return .top }
        let distances: [(PanelEdge, CGFloat)] = [
            (.top, point.y),
            (.bottom, size.height - point.y),
            (.leading, point.x),
            (.trailing, size.width - point.x),
        ]
        var best = distances[0]
        for candidate in distances.dropFirst() where candidate.1 < best.1 {
            best = candidate
        }
        return best.0
    }
}
