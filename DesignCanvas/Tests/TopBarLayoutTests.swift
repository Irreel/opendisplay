import CoreGraphics
import XCTest

final class TopBarLayoutTests: XCTestCase {

    // Figma v3.1: a 150-point session pill, the 60-point window button under
    // it, the prompt pill at its narrowest, the full tool panel on an iPad
    // and the compact one on an iPhone, and the reply card.
    private let pill: CGFloat = 150
    private let windowButton: CGFloat = 60
    private let prompt: CGFloat = 220
    private let fullPanel: CGFloat = 449
    private let compactPanel: CGFloat = 289
    private let card: CGFloat = 340

    // MARK: - iPad

    func test_iPadLandscape_drawing_promptSharesTheTopRow() {
        let layout = TopBarLayout(width: 1194, left: pill, secondLeft: windowButton, right: prompt,
                                  panel: nil, card: nil)
        XCTAssertEqual(layout.rightRow, 0)
        XCTAssertEqual(layout.left, pill)
    }

    func test_iPadLandscape_topDockedPanel_takesTheCentreOfTheTopRow() {
        let layout = TopBarLayout(width: 1194, left: pill, secondLeft: windowButton, right: prompt,
                                  panel: fullPanel, card: nil)
        XCTAssertEqual(layout.panelRow, 0)
        XCTAssertEqual(layout.rightRow, 0)
    }

    func test_iPadPortrait_topDockedPanel_takesTheSecondRow_besideTheWindowButton() {
        let layout = TopBarLayout(width: 820, left: pill, secondLeft: windowButton, right: prompt,
                                  panel: fullPanel, card: nil)
        XCTAssertEqual(layout.panelRow, 1)
    }

    func test_iPad_drawing_theCardHangsUnderThePrompt() {
        let layout = TopBarLayout(width: 1194, left: pill, secondLeft: windowButton, right: prompt,
                                  panel: nil, card: card)
        XCTAssertEqual(layout.rightRow, 0)
        XCTAssertEqual(layout.cardRow, 1)
    }

    func test_iPad_live_theCardTakesTheTopRight() {
        let layout = TopBarLayout(width: 1194, left: pill, secondLeft: windowButton, right: nil,
                                  panel: nil, card: card)
        XCTAssertEqual(layout.cardRow, 0)
    }

    // MARK: - iPhone

    func test_iPhonePortrait_drawing_thePromptSitsBesideTheWindowButton() {
        let layout = TopBarLayout(width: 393, left: pill, secondLeft: windowButton, right: prompt,
                                  panel: nil, card: nil)
        XCTAssertEqual(layout.rightRow, 1)
    }

    func test_iPhonePortrait_topDockedPanel_takesTheThirdRow() {
        let layout = TopBarLayout(width: 393, left: pill, secondLeft: windowButton, right: prompt,
                                  panel: compactPanel, card: nil)
        XCTAssertEqual(layout.rightRow, 1)
        XCTAssertEqual(layout.panelRow, 2)
    }

    func test_iPhonePortrait_drawing_theCardTakesTheRowUnderThePrompt() {
        let layout = TopBarLayout(width: 393, left: pill, secondLeft: windowButton, right: prompt,
                                  panel: nil, card: card)
        XCTAssertEqual(layout.cardRow, 2)
    }

    func test_iPhoneLandscape_thePromptSharesTheTopRow() {
        let layout = TopBarLayout(width: 734, left: pill, secondLeft: windowButton, right: prompt,
                                  panel: nil, card: nil)
        XCTAssertEqual(layout.rightRow, 0)
    }

    func test_iPhone_live_theCardWaitsBelowTheWindowButton() {
        let layout = TopBarLayout(width: 393, left: pill, secondLeft: windowButton, right: nil,
                                  panel: nil, card: card)
        XCTAssertEqual(layout.cardRow, 2)
    }

    // MARK: - Edges

    func test_aPanelDockedElsewhereTakesNoRow() {
        let layout = TopBarLayout(width: 393, left: pill, right: nil, panel: nil, card: card)
        XCTAssertNil(layout.panelRow)
        XCTAssertEqual(layout.cardRow, 1)
    }

    func test_aCardWiderThanTheScreenStillGetsARow() {
        let layout = TopBarLayout(width: 300, left: 100, right: nil, panel: nil, card: card)
        XCTAssertEqual(layout.cardRow, 1)
    }

    func test_offset_isSixtyPointsARow() {
        XCTAssertEqual(TopBarLayout.offset(nil), 0)
        XCTAssertEqual(TopBarLayout.offset(0), 0)
        XCTAssertEqual(TopBarLayout.offset(2), 120)
    }
}
