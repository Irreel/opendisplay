import XCTest

/// `SenderDiscoveryConfig` is the part of `SenderControllerConfig` that names
/// no AppKit or ScreenCaptureKit type, so it is the part a hostless bundle can
/// compile. Its defaults are OpenDisplay's own discovery constants: leaving
/// them alone has to keep dialing `_opensidecar._tcp` on 9000, because the
/// controller now reads them instead of the literals it used to carry.
final class SenderControllerConfigTests: XCTestCase {

    func testDefaultDiscoveryConfigCarriesOpenDisplaysBonjourTypeAndPort() {
        let discovery = SenderDiscoveryConfig()
        XCTAssertEqual(discovery.bonjourType, "_opensidecar._tcp")
        XCTAssertEqual(discovery.devicePort, 9000)
    }

    /// Design Canvas advertises its own service on its own port (ruling 1:
    /// USB dialing has no Bonjour type, so the port is what keeps the two
    /// products from dialing each other). Both values must therefore be
    /// settable through the memberwise initializer.
    func testDiscoveryConfigTakesADifferentServiceTypeAndPort() {
        let discovery = SenderDiscoveryConfig(bonjourType: "_designcanvas._tcp",
                                              devicePort: 9100)
        XCTAssertEqual(discovery.bonjourType, "_designcanvas._tcp")
        XCTAssertEqual(discovery.devicePort, 9100)
    }
}
