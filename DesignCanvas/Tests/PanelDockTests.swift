import CoreGraphics
import XCTest

final class PanelDockTests: XCTestCase {

    private let size = CGSize(width: 1194, height: 834)

    func test_nearest_snapsToTheClosestEdge() {
        XCTAssertEqual(PanelEdge.nearest(to: CGPoint(x: 600, y: 30), in: size), .top)
        XCTAssertEqual(PanelEdge.nearest(to: CGPoint(x: 600, y: 800), in: size), .bottom)
        XCTAssertEqual(PanelEdge.nearest(to: CGPoint(x: 40, y: 400), in: size), .leading)
        XCTAssertEqual(PanelEdge.nearest(to: CGPoint(x: 1150, y: 400), in: size), .trailing)
    }

    func test_nearest_aCornerGoesToWhicheverEdgeIsCloser() {
        XCTAssertEqual(PanelEdge.nearest(to: CGPoint(x: 100, y: 20), in: size), .top)
        XCTAssertEqual(PanelEdge.nearest(to: CGPoint(x: 20, y: 100), in: size), .leading)
    }

    func test_nearest_aDropOutsideTheScreenStillSnaps() {
        XCTAssertEqual(PanelEdge.nearest(to: CGPoint(x: 600, y: -50), in: size), .top)
        XCTAssertEqual(PanelEdge.nearest(to: CGPoint(x: 1400, y: 400), in: size), .trailing)
    }

    func test_nearest_withNoSizeYetIsTheDefaultEdge() {
        XCTAssertEqual(PanelEdge.nearest(to: CGPoint(x: 10, y: 10), in: .zero), .top)
    }

    func test_restingCenter_isTheMiddleOfTheEdge() {
        XCTAssertEqual(PanelEdge.top.restingCenter(in: size, inset: 40), CGPoint(x: 597, y: 40))
        XCTAssertEqual(PanelEdge.bottom.restingCenter(in: size, inset: 40), CGPoint(x: 597, y: 794))
        XCTAssertEqual(PanelEdge.leading.restingCenter(in: size, inset: 40), CGPoint(x: 40, y: 417))
        XCTAssertEqual(PanelEdge.trailing.restingCenter(in: size, inset: 40), CGPoint(x: 1154, y: 417))
    }

    func test_restingCenter_roundTripsThroughNearest() {
        for edge in PanelEdge.allCases {
            XCTAssertEqual(PanelEdge.nearest(to: edge.restingCenter(in: size, inset: 40), in: size), edge)
        }
    }

    func test_isVertical_onlyOnTheSides() {
        XCTAssertEqual(PanelEdge.allCases.filter(\.isVertical), [.leading, .trailing])
    }
}
