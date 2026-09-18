import XCTest

/// `SenderDisplayIdentity` names the virtual display a sender creates: the
/// productID it starts from and the brand in its name. macOS keys saved display
/// state on vendor/product/serial, so the defaults must stay exactly what
/// OpenDisplay shipped — moving them would orphan every user's saved
/// arrangement, and every identity offset persisted for a poisoned display.
final class SenderDisplayIdentityTests: XCTestCase {

    func testDefaultIdentityIsOpenDisplaysShippedOne() {
        let identity = SenderDisplayIdentity()
        XCTAssertEqual(identity.productIDBase, 0x4F53)   // "OS"
        XCTAssertEqual(identity.namePrefix, "OpenDisplay")
    }

    /// The productID moves with the serial when an identity is abandoned
    /// (#206: some macOS versions key the hostile state on the product).
    func testProductIDMovesWithTheIdentityOffset() {
        let identity = SenderDisplayIdentity()
        XCTAssertEqual(identity.productID(offset: 0), 0x4F53)
        XCTAssertEqual(identity.productID(offset: 2), 0x4F55)
    }

    func testProductIDWrapsRatherThanTrapping() {
        let identity = SenderDisplayIdentity(productIDBase: .max, namePrefix: "X")
        XCTAssertEqual(identity.productID(offset: 1), 0)
    }

    func testDisplayNameCarriesTheBrandAndTheDeviceName() {
        let identity = SenderDisplayIdentity()
        XCTAssertEqual(identity.displayName(endpointName: "iPadz", kind: "iPad"),
                       "OpenDisplay — iPadz")
    }

    /// USB sessions can start before lockdown resolves the device name — the
    /// generic label gives way to the kind from the hello.
    func testDisplayNameFallsBackToTheKindForTheGenericUSBLabel() {
        let identity = SenderDisplayIdentity()
        XCTAssertEqual(identity.displayName(endpointName: "iPhone / iPad (USB)", kind: "iPad"),
                       "OpenDisplay — iPad")
    }
}
