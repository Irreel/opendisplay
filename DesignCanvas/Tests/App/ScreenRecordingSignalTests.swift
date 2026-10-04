import XCTest

/// What feeds the menu's Screen Recording row. On macOS 26 `CGPreflightScreenCaptureAccess()`
/// was seen returning false on the app's poll while the very same process was mirroring the
/// screen (2026-09-30 hardware session), so a capturing engine outranks the preflight; the
/// preflight only decides when nothing is being captured.
@MainActor
final class ScreenRecordingSignalTests: XCTestCase {
    private final class Flag { var value = false }

    private func makeModel(engine: FakeSenderEngine, preflight: Flag) -> AppModel {
        AppModel(
            probe: { .refused },
            now: Date.init,
            childPidProvider: { nil },
            engine: engine,
            screenRecordingProbe: { preflight.value }
        )
    }

    func testCapturingEngineCountsAsGrantedWhenThePreflightSaysNo() async {
        let engine = FakeSenderEngine()
        engine.isCapturing = true
        let model = makeModel(engine: engine, preflight: Flag())
        await model.pollOnce()
        XCTAssertTrue(model.screenRecordingGranted)
    }

    func testPreflightDrivesTheRowWhenNothingIsCapturing() async {
        let preflight = Flag()
        let model = makeModel(engine: FakeSenderEngine(), preflight: preflight)
        await model.pollOnce()
        XCTAssertFalse(model.screenRecordingGranted)
        preflight.value = true
        await model.pollOnce()
        XCTAssertTrue(model.screenRecordingGranted)
    }

    func testInitialValueComesFromTheInjectedPreflight() {
        let preflight = Flag()
        preflight.value = true
        let model = makeModel(engine: FakeSenderEngine(), preflight: preflight)
        XCTAssertTrue(model.screenRecordingGranted)
    }
}
