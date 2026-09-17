import XCTest

/// Ported from ai.cst.2 `DesignCanvasDesktopTests/ProjectRecentsTests.swift`.
final class ProjectRecentsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    func testAddMovesToFrontAndDedupes() {
        let r = ProjectRecents(defaults: freshDefaults(), max: 5)
        r.add(URL(fileURLWithPath: "/a"))
        r.add(URL(fileURLWithPath: "/b"))
        r.add(URL(fileURLWithPath: "/a"))
        XCTAssertEqual(r.all.map(\.path), ["/a", "/b"])
    }

    func testCapsAtMax() {
        let r = ProjectRecents(defaults: freshDefaults(), max: 2)
        ["/a", "/b", "/c"].forEach { r.add(URL(fileURLWithPath: $0)) }
        XCTAssertEqual(r.all.map(\.path), ["/c", "/b"])
    }
}
