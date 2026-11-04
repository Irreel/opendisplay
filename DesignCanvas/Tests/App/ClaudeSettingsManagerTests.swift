import XCTest

/// "Use Design Canvas in every Claude Code session" (X20) is one entry in the user's own
/// Claude Code settings file. These pin the rules for touching it: one value changes, every
/// other key stays, a file that does not parse is never rewritten, and off removes exactly
/// what on added.
final class ClaudeSettingsManagerTests: XCTestCase {
    private var dir: URL!
    private var file: URL!
    private var manager: ClaudeSettingsManager!
    private let mod = "/Applications/Design Canvas.app/Contents/Resources/mod"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-settings-\(UUID().uuidString)")
        file = dir.appendingPathComponent(".claude/settings.json")
        manager = ClaudeSettingsManager(settingsURL: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func root() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    func testAddCreatesTheFileWhenThereIsNone() throws {
        XCTAssertFalse(manager.contains(mod))
        try manager.add(mod)
        XCTAssertEqual(try manager.directories(), [mod])
        XCTAssertTrue(manager.contains(mod))
        let env = try XCTUnwrap(try root()["env"] as? [String: Any])
        XCTAssertEqual(env[ClaudeSettingsManager.variable] as? String, mod, "the path is written whole, spaces and all")
    }

    func testAddKeepsEveryOtherKeyAndEveryOtherDirectory() throws {
        try write(#"{"model":"opus","env":{"FOO":"1","CLAUDE_CODE_PLUGIN_DIRS":"/a/one:/b/two"},"hooks":{"Stop":[]}}"#)
        try manager.add(mod)
        let after = try root()
        XCTAssertEqual(after["model"] as? String, "opus")
        XCTAssertNotNil(after["hooks"])
        let env = try XCTUnwrap(after["env"] as? [String: Any])
        XCTAssertEqual(env["FOO"] as? String, "1")
        XCTAssertEqual(try manager.directories(), ["/a/one", "/b/two", mod], "others keep their place; ours goes last")
    }

    func testAddIsIdempotentAndDoesNotRewriteAnUnchangedFile() throws {
        try manager.add(mod)
        let before = try Data(contentsOf: file)
        let stamp = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try manager.add(mod)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, stamp)
        XCTAssertEqual(try manager.directories(), [mod])
    }

    func testAddReplacesTheOldPathOfAMovedApp() throws {
        let old = "/Users/me/Downloads/Design Canvas.app/Contents/Resources/mod"
        try write(#"{"env":{"CLAUDE_CODE_PLUGIN_DIRS":"/a/one:\#(old)"}}"#)
        try manager.add(mod, replacing: old)
        XCTAssertEqual(try manager.directories(), ["/a/one", mod])
    }

    func testRemoveTakesOutExactlyWhatAddPutIn() throws {
        try write(#"{"model":"opus","env":{"FOO":"1"}}"#)
        let before = try root() as NSDictionary
        try manager.add(mod)
        try manager.remove(mod)
        XCTAssertEqual(try root() as NSDictionary, before, "the variable is gone, env and the rest are as they were")
    }

    func testRemoveDropsEnvWhenItWasOursAlone() throws {
        try write(#"{"model":"opus"}"#)
        try manager.add(mod)
        try manager.remove(mod)
        let after = try root()
        XCTAssertNil(after["env"], "an env this app created is not left behind empty")
        XCTAssertEqual(after["model"] as? String, "opus")
    }

    func testRemoveLeavesOtherDirectoriesAndIsQuietWhenThereIsNothingToRemove() throws {
        try manager.remove(mod)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing to remove writes nothing")

        try write(#"{"env":{"CLAUDE_CODE_PLUGIN_DIRS":"/a/one:\#(mod):/b/two"}}"#)
        try manager.remove(mod)
        XCTAssertEqual(try manager.directories(), ["/a/one", "/b/two"])
    }

    func testAMalformedFileIsNeverRewritten() throws {
        let broken = "{ this is not json"
        try write(broken)
        XCTAssertThrowsError(try manager.add(mod)) { error in
            XCTAssertEqual(error as? ClaudeSettingsError, .malformed(file.path))
        }
        XCTAssertThrowsError(try manager.remove(mod))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken)
        XCTAssertFalse(manager.contains(mod))

        try write("[1, 2, 3]")
        XCTAssertThrowsError(try manager.add(mod), "valid JSON that is not an object is not ours to rewrite either")
    }
}
