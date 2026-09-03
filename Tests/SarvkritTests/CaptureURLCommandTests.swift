import XCTest
@testable import Sarvkrit

/// The `sarvkrit://` scheme.
///
/// The rule worth pinning: an unrecognised command does *nothing*. Defaulting a typo to some
/// capture mode would mean a script with a spelling mistake quietly takes screenshots.
final class CaptureURLCommandTests: XCTestCase {

    private func parse(_ string: String) -> CaptureURLCommand? {
        guard let url = URL(string: string) else { return nil }
        return CaptureURLCommand.parse(url)
    }

    func testEveryCaptureModeHasACommand() {
        // The counterpart of `testEveryCaptureModeIsReachableByShortcut`: a mode reachable by key
        // but not by script is a mode Raycast and Shortcuts cannot see.
        for action in ScreenshotAction.allCases {
            let command = CaptureURLCommand.action(action)
            XCTAssertEqual(parse("sarvkrit://\(command.name)"), command, "\(action.rawValue)")
        }
    }

    func testTheCommandNamesFollowTheOnesScriptsAlreadyUse() {
        XCTAssertEqual(parse("sarvkrit://capture-area"), .action(.area))
        XCTAssertEqual(parse("sarvkrit://capture-window"), .action(.window))
        XCTAssertEqual(parse("sarvkrit://capture-fullscreen"), .action(.fullscreen))
        XCTAssertEqual(parse("sarvkrit://all-in-one"), .action(.allInOne))
        XCTAssertEqual(parse("sarvkrit://scrolling-capture"), .action(.scrolling))
        XCTAssertEqual(parse("sarvkrit://capture-text"), .action(.textRecognition))
        XCTAssertEqual(parse("sarvkrit://open-history"), .action(.history))
        XCTAssertEqual(parse("sarvkrit://restore-recently-closed"), .action(.restoreOverlay))
    }

    func testCancelIsReachable() {
        // The scriptable escape hatch. It has to work even when everything else is wedged, which
        // is the one case where its own name being wrong would be unrecoverable.
        XCTAssertEqual(parse("sarvkrit://cancel"), .cancel)
    }

    func testTheNumberOfSlashesIsNotLoadBearing() {
        XCTAssertEqual(parse("sarvkrit:///capture-area"), .action(.area))
        XCTAssertEqual(parse("sarvkrit:capture-area"), .action(.area))
        XCTAssertEqual(parse("sarvkrit://capture-area/"), .action(.area))
        XCTAssertEqual(parse("sarvkrit://CAPTURE-AREA"), .action(.area))
        XCTAssertEqual(parse("SARVKRIT://capture-area"), .action(.area))
    }

    func testAQueryStringIsIgnoredRatherThanRejected() {
        // Room for parameters later without breaking links written today.
        XCTAssertEqual(parse("sarvkrit://capture-area?display=1"), .action(.area))
    }

    func testATypoDoesNothing() {
        XCTAssertNil(parse("sarvkrit://capture-are"))
        XCTAssertNil(parse("sarvkrit://"))
        XCTAssertNil(parse("sarvkrit://../../etc/passwd"))
        XCTAssertNil(parse("cleanshot://capture-area"), "another app's scheme is not ours")
        XCTAssertNil(parse("https://capture-area"))
    }

    func testEveryCommandNameIsDistinct() {
        let names = CaptureURLCommand.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "two commands share a name: \(names)")
    }
}
