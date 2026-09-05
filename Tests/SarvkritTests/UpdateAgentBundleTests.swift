import XCTest
@testable import Sarvkrit

/// The unit tests are hosted *inside* Sarvkrit.app, so `Bundle.main` here is the real app bundle.
/// That makes this the only automated catch for a launch agent that was built into the wrong
/// place — and every failure it catches is otherwise completely silent. A plist in
/// Contents/Resources instead of Contents/Library/LaunchAgents, a BundleProgram pointing at
/// nothing, or a script that lost its executable bit all present identically: the job never runs,
/// the file the app reads never appears, and the app says "not checked yet" forever.
final class UpdateAgentBundleTests: XCTestCase {
    private func appBundle() throws -> Bundle {
        let bundle = Bundle.main
        try XCTSkipUnless(
            bundle.bundleIdentifier == AppIdentity.bundleID,
            "not hosted in Sarvkrit.app — nothing to check")
        return bundle
    }

    private func agentPlist() throws -> [String: Any] {
        let bundle = try appBundle()
        let url = bundle.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(UpdateCheckAgent.label + ".plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the launch agent is not in Contents/Library/LaunchAgents — SMAppService will never find it")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// SMAppService resolves the job by filename; launchd identifies it by Label. If those two
    /// disagree the only symptom is a registration that quietly fails.
    func testLabelMatchesTheFilenameAndTheBundleID() throws {
        let plist = try agentPlist()
        XCTAssertEqual(plist["Label"] as? String, UpdateCheckAgent.label)
        XCTAssertTrue(UpdateCheckAgent.label.hasPrefix(AppIdentity.bundleID + "."))
    }

    /// Without this the Login Items row is an unattributed job label. The user's ability to see
    /// and switch off the network access is the reason this design exists at all.
    func testJobIsAttributedToTheApp() throws {
        let plist = try agentPlist()
        let associated = plist["AssociatedBundleIdentifiers"] as? [String]
        XCTAssertEqual(associated, [AppIdentity.bundleID])
    }

    func testBundleProgramResolvesToAnExecutableScript() throws {
        let bundle = try appBundle()
        let program = try XCTUnwrap(try agentPlist()["BundleProgram"] as? String)
        let script = bundle.bundleURL.appendingPathComponent(program)
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path),
                      "BundleProgram points at \(program), which is not in the bundle")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path),
                      "\(program) is not executable — launchd will fail the spawn and nothing will say so")
    }

    /// A daily interval is skipped outright if the Mac is asleep when it comes due, so a laptop
    /// that closes overnight would never check. The short interval plus the script's own throttle
    /// is what makes the check both reliable and once-a-day.
    func testIntervalIsShortEnoughToSurviveSleep() throws {
        let interval = try XCTUnwrap(try agentPlist()["StartInterval"] as? Int)
        XCTAssertLessThanOrEqual(interval, 60 * 60 * 8)
        XCTAssertGreaterThanOrEqual(interval, 60 * 60)
    }

    /// The sources sweep in project.yml copies everything under Sources/Sarvkrit into
    /// Contents/Resources. A second copy of the plist landing there would mean the one that
    /// matters could silently be the wrong file.
    func testTheAgentPlistIsNotAlsoCopiedIntoResources() throws {
        let bundle = try appBundle()
        let stray = bundle.bundleURL
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent(UpdateCheckAgent.label + ".plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    /// "Check Now" locates the script through `Bundle.url(forResource:)` with a nil extension,
    /// which is a slightly unusual call for a name that already contains a dot. If it ever stops
    /// resolving, the button silently does nothing.
    func testCheckNowCanFindTheScriptThroughTheBundleAPI() throws {
        _ = try appBundle()
        let url = Bundle.main.url(forResource: UpdateCheckAgent.scriptName, withExtension: nil)
        XCTAssertNotNil(url, "Bundle lookup for \(UpdateCheckAgent.scriptName) failed")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(url).path))
    }

    func testABuildDirectoryIsNotAnInstalledLocation() {
        XCTAssertFalse(UpdateCheckAgent.isInstalledLocation(
            URL(fileURLWithPath: "/Users/x/dev/build/Release/Sarvkrit.app")))
        XCTAssertTrue(UpdateCheckAgent.isInstalledLocation(
            URL(fileURLWithPath: "/Applications/Sarvkrit.app")))
        XCTAssertTrue(UpdateCheckAgent.isInstalledLocation(
            URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Sarvkrit.app")))
    }
}
