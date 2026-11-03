import XCTest

/// The prompt the iPad's setup guide copies has Claude Code make the change the Mac app's
/// "every session" switch makes (X20). These hold the two together: if the app moves its mod,
/// or the switch writes another variable or file, the prompt has to change with it, or the
/// switch would not see what the prompt turned on.
@MainActor
final class SetupGuideTests: XCTestCase {
    private let app = "/Applications/Design Canvas.app"

    func testPromptPointsAtTheModTheAppRegisters() throws {
        var probed: [String] = []
        let resources = URL(fileURLWithPath: app + "/Contents/Resources")
        let mod = try XCTUnwrap(AppModel.defaultModDirectory(resources: resources, roots: []) {
            probed.append($0)
            return true
        })
        XCTAssertTrue(mod.hasPrefix(app + "/"))
        XCTAssertTrue(SetupGuide.modPrompt.contains("the folder \(mod.dropFirst(app.count + 1)) inside the app"))

        let entry = try XCTUnwrap(probed.first)
        XCTAssertTrue(entry.hasPrefix(mod + "/"))
        XCTAssertTrue(SetupGuide.modPrompt.contains("Check that \(entry.dropFirst(mod.count + 1)) is in it"))
    }

    func testPromptEditsTheSettingTheSwitchReads() {
        XCTAssertTrue(SetupGuide.modPrompt.contains("env.\(ClaudeSettingsManager.variable) in "))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let settings = ClaudeSettingsManager().settingsURL.path
        XCTAssertTrue(settings.hasPrefix(home + "/"))
        XCTAssertTrue(SetupGuide.modPrompt.contains("~/\(settings.dropFirst(home.count + 1))"))
    }

    func testPromptFindsTheReleaseApp() {
        XCTAssertTrue(SetupGuide.modPrompt.contains("kMDItemCFBundleIdentifier == '\(SetupGuide.macBundleID)'"))
    }
}
