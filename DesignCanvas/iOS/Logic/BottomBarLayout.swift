// Where the tool panel sits against the drawing button (Figma v3.1). The
// button (Start drawing, End drawing) is at the bottom left. A panel docked
// at the bottom is centred on the screen when that leaves the button its
// room; otherwise it is centred in the room right of the button, as on an
// iPhone; and where even that is too narrow, it takes the row above the
// button. A panel docked on the left is moved up, if it has to be, so it
// ends above the button.
//
// Widths are the pieces' own, without the 16-point screen margins or the
// 8-point gap between them, which are added here.
//
// CoreGraphics only: this is compiled into the hostless test bundle.

import CoreGraphics

struct BottomBarLayout: Equatable {

    static let margin: CGFloat = 16
    static let gap: CGFloat = 8

    /// How far right of the screen's centre the panel's centre is.
    private(set) var panelShift: CGFloat = 0
    /// How far up from where it would rest the panel is.
    private(set) var panelRaise: CGFloat = 0

    /// - Parameters:
    ///   - size: the safe area.
    ///   - edge: the edge the panel is docked to.
    ///   - panelLength: the panel along its edge.
    ///   - panelThickness: the panel across its edge.
    ///   - button: the drawing button's size, when it is up.
    init(size: CGSize, edge: PanelEdge, panelLength: CGFloat, panelThickness: CGFloat,
         button: CGSize?) {
        guard let button else { return }
        switch edge {
        case .bottom:
            let buttonRoom = Self.margin + button.width + Self.gap
            if (size.width - panelLength) / 2 >= buttonRoom {
                return
            }
            let room = size.width - buttonRoom - Self.margin
            if room >= panelLength {
                // Centred between the button and the right margin.
                panelShift = (buttonRoom + room / 2) - size.width / 2
            } else {
                panelRaise = button.height + Self.gap
            }
        case .leading:
            let bottom = (size.height + panelLength) / 2
            let limit = size.height - Self.margin - button.height - Self.gap
            panelRaise = max(0, bottom - limit)
        case .top, .trailing:
            return
        }
    }
}
