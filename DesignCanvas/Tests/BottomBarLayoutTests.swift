import CoreGraphics
import XCTest

final class BottomBarLayoutTests: XCTestCase {

    // The round drawing button, bottom left.
    private let endDrawing = CGSize(width: 56, height: 56)

    func test_iPadLandscape_thePanelIsCentredOnTheScreen() {
        let layout = BottomBarLayout(size: CGSize(width: 1194, height: 790), edge: .bottom,
                                     panelLength: 449, panelThickness: 56, button: endDrawing)
        XCTAssertEqual(layout.panelShift, 0)
        XCTAssertEqual(layout.panelRaise, 0)
    }

    func test_iPadPortrait_thePanelIsCentredOnTheScreen() {
        let layout = BottomBarLayout(size: CGSize(width: 820, height: 1140), edge: .bottom,
                                     panelLength: 449, panelThickness: 56, button: endDrawing)
        XCTAssertEqual(layout.panelShift, 0)
        XCTAssertEqual(layout.panelRaise, 0)
    }

    func test_iPhoneLandscape_theFullPanelIsCentredOnTheScreen() {
        let layout = BottomBarLayout(size: CGSize(width: 734, height: 372), edge: .bottom,
                                     panelLength: 449, panelThickness: 56, button: endDrawing)
        XCTAssertEqual(layout.panelShift, 0)
        XCTAssertEqual(layout.panelRaise, 0)
    }

    func test_iPhonePortrait_theCompactPanelIsCentredRightOfTheButton() {
        let layout = BottomBarLayout(size: CGSize(width: 393, height: 790), edge: .bottom,
                                     panelLength: 289, panelThickness: 56, button: endDrawing)
        // Between the button and the margin: 80 + (393 - 80 - 16) / 2.
        XCTAssertEqual(layout.panelShift, 80 + 148.5 - 196.5)
        XCTAssertEqual(layout.panelRaise, 0)
    }

    func test_tooNarrowBesideTheButton_thePanelTakesTheRowAbove() {
        let layout = BottomBarLayout(size: CGSize(width: 375, height: 790), edge: .bottom,
                                     panelLength: 289, panelThickness: 56, button: endDrawing)
        XCTAssertEqual(layout.panelShift, 0)
        XCTAssertEqual(layout.panelRaise, 64)
    }

    func test_theWhiteboard_hasNoButton_soThePanelIsCentred() {
        let layout = BottomBarLayout(size: CGSize(width: 393, height: 790), edge: .bottom,
                                     panelLength: 289, panelThickness: 56, button: nil)
        XCTAssertEqual(layout, BottomBarLayout(size: .zero, edge: .top, panelLength: 0,
                                               panelThickness: 0, button: nil))
    }

    func test_onTheLeft_aTallPanelEndsAboveTheButton() {
        let layout = BottomBarLayout(size: CGSize(width: 734, height: 372), edge: .leading,
                                     panelLength: 289, panelThickness: 56, button: endDrawing)
        // Its bottom, 330.5, goes up to 372 - 16 - 56 - 8.
        XCTAssertEqual(layout.panelRaise, 330.5 - 292)
    }

    func test_onTheLeft_aShortPanelStaysCentred() {
        let layout = BottomBarLayout(size: CGSize(width: 1194, height: 790), edge: .leading,
                                     panelLength: 449, panelThickness: 56, button: endDrawing)
        XCTAssertEqual(layout.panelRaise, 0)
    }

    func test_atTheTopOrOnTheRight_theButtonIsNotInTheWay() {
        for edge in [PanelEdge.top, .trailing] {
            let layout = BottomBarLayout(size: CGSize(width: 393, height: 372), edge: edge,
                                         panelLength: 289, panelThickness: 56, button: endDrawing)
            XCTAssertEqual(layout.panelShift, 0)
            XCTAssertEqual(layout.panelRaise, 0)
        }
    }
}
