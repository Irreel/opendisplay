// Which row each piece of the top of the screen sits in (Figma v3.1). The
// session pill opens the first row on the left and the window button the
// second. On an iPad the right-hand item (the prompt pill while drawing, the
// kept sketch's chip between sketches) shares the first row, and only the
// tool panel and the reply card ever drop a row. An iPhone is too narrow for
// that: there the right-hand item takes the second row, beside the window
// button, and a top-docked panel and the reply card each take the first row
// where they fit. A panel docked anywhere else is not in the top rows at all.
//
// Widths are the pieces' own, without the 16-point screen margins or the
// 8-point gaps between them, which are added here. Each row is 60 points
// below the last: a 44-point control and the space under it.
//
// CoreGraphics only: this is compiled into the hostless test bundle.

import CoreGraphics

struct TopBarLayout: Equatable {

    static let rowPitch: CGFloat = 60
    static let margin: CGFloat = 16
    static let gap: CGFloat = 8

    /// The right-hand item's row: beside the left-hand group when both fit.
    private(set) var rightRow = 0
    /// The panel's row, when it is docked to the top.
    private(set) var panelRow: Int?
    /// The reply card's row, when one is up. Always below the right-hand item,
    /// which it hangs under.
    private(set) var cardRow: Int?
    /// The left-hand group of the top row as laid out.
    private(set) var left: CGFloat = 0

    /// - Parameters:
    ///   - width: the safe area's width.
    ///   - left: the session pill; 0 when there is none.
    ///   - secondLeft: the window button, at the left of the second row; 0
    ///     when there is none.
    ///   - right: the right-hand item, when there is one: the narrowest it
    ///     can be, since the prompt pill stretches to the room it is given.
    ///   - panel: the panel's width, when it is docked to the top.
    ///   - card: the reply card's width, when one is up.
    init(width: CGFloat, left: CGFloat, secondLeft: CGFloat = 0, right: CGFloat?, panel: CGFloat?,
         card: CGFloat?) {
        self.left = left
        var rows: [(left: CGFloat, right: CGFloat)] = [(left, 0)]
        if secondLeft > 0 { rows.append((secondLeft, 0)) }
        func row(_ index: Int) -> (left: CGFloat, right: CGFloat) {
            index < rows.count ? rows[index] : (0, 0)
        }
        func occupy(_ index: Int, right width: CGFloat) {
            while rows.count <= index { rows.append((0, 0)) }
            rows[index].right = width
        }
        /// Whether `item` fits at the right of a row beside what is on its left.
        func fitsRight(_ item: CGFloat, in index: Int) -> Bool {
            let used = row(index)
            guard used.right == 0 else { return false }
            let left = used.left > 0 ? used.left + Self.gap : 0
            return Self.margin + left + item + Self.margin <= width
        }

        if let right {
            rightRow = fitsRight(right, in: 0) ? 0 : 1
            occupy(rightRow, right: right)
        }

        // A centred panel needs as much room on each side as the wider of
        // what the row holds at its two ends.
        if let panel {
            let side = (width - panel) / 2
            var index = 0
            while true {
                let used = row(index)
                let widest = max(used.left, used.right)
                if widest == 0 || side >= Self.margin + widest + Self.gap { break }
                index += 1
            }
            panelRow = index
        }

        if let card {
            var index = right == nil ? 0 : rightRow + 1
            while true {
                let besidePanel = panelRow != index || (width - (panel ?? 0)) / 2 >= Self.margin + card + Self.gap
                if besidePanel && fitsRight(card, in: index) { break }
                // A row of its own, even on a screen narrower than the card.
                if panelRow != index && row(index) == (0, 0) { break }
                index += 1
            }
            cardRow = index
        }
    }

    /// How far below the top row `row` is.
    static func offset(_ row: Int?) -> CGFloat {
        CGFloat(row ?? 0) * rowPitch
    }
}
