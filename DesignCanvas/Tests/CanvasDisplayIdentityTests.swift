import XCTest

/// Design Canvas and OpenDisplay derive the same display serial for the same
/// cabled iPad (a hash of `usb:<udid>`), and macOS keys saved display state on
/// vendor/product/serial. Sharing a productID therefore means sharing that
/// state — including the hostile state that keeps an identity from ever coming
/// online again, while the offset that escapes it is persisted in the *other*
/// app's defaults. Seen on hardware: Design Canvas spent its whole three-probe
/// budget on identities OpenDisplay had already abandoned, and never mirrored.
final class CanvasDisplayIdentityTests: XCTestCase {

    /// Serial and productID move by the same offset, so two namespaces collide
    /// exactly when their productIDs are equal at the same offset.
    func testDesignCanvasNeverSharesAnIdentityWithOpenDisplay() {
        let openDisplay = SenderDisplayIdentity()
        let canvas = SenderDisplayIdentity.designCanvas
        for offset in UInt32(0)..<4096 {
            XCTAssertNotEqual(canvas.productID(offset: offset), openDisplay.productID(offset: offset))
        }
    }

    /// Far enough apart that neither product's offsets reach the other's base:
    /// an identity is only ever abandoned a handful of times per device.
    func testTheTwoProductRangesAreFarApart() {
        let gap = Int64(SenderDisplayIdentity().productIDBase) - Int64(SenderDisplayIdentity.designCanvas.productIDBase)
        XCTAssertGreaterThan(abs(gap), 1024)
    }

    func testDisplaysAreNamedForDesignCanvas() {
        XCTAssertEqual(SenderDisplayIdentity.designCanvas.displayName(endpointName: "iPadz", kind: "iPad"),
                       "Design Canvas — iPadz")
    }
}
