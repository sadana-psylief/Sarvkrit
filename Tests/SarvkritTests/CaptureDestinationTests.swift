import XCTest
@testable import Sarvkrit

/// The routing policy, as a table.
final class CaptureDestinationTests: XCTestCase {

    func testTheDefaultSettingsFileAndShowTheOverlay() {
        let plan = CaptureDestination.plan(for: .area, settings: .init())
        XCTAssertTrue(plan.writesFile)
        XCTAssertTrue(plan.showsOverlay)
        XCTAssertFalse(plan.writesClipboard)
    }

    func testTextRecognitionGoesOnlyToTheClipboard() {
        // Even with every image destination switched on: the point of OCR is the text, and filing
        // a PNG of it would leave junk in the capture folder after every lookup.
        let everything = CaptureDestination.Settings(
            savesToDisk: true, copiesToClipboard: true, showsQuickAccess: true, opensEditor: true)
        let plan = CaptureDestination.plan(for: .textRecognition, settings: everything)
        XCTAssertEqual(plan, CaptureDestination.Plan(
            writesFile: false, writesClipboard: true, showsOverlay: false, opensEditor: false))
    }

    func testACaptureNeverGoesNowhere() {
        // Every destination off would make the shortcut look broken. The clipboard is the fallback
        // because it can't itself be unavailable.
        let nothing = CaptureDestination.Settings(
            savesToDisk: false, copiesToClipboard: false, showsQuickAccess: false, opensEditor: false)
        let plan = CaptureDestination.plan(for: .area, settings: nothing)
        XCTAssertFalse(plan.isEmpty)
        XCTAssertTrue(plan.writesClipboard)
    }

    func testTheOverlayForcesAFileEvenWhenSavingIsOff() {
        // The overlay drags a file URL out; there has to be a file behind it before it appears.
        let settings = CaptureDestination.Settings(
            savesToDisk: false, copiesToClipboard: true, showsQuickAccess: true, opensEditor: false)
        XCTAssertTrue(CaptureDestination.plan(for: .area, settings: settings).writesFile)
    }

    func testTheEditorForcesAFileToo() {
        let settings = CaptureDestination.Settings(
            savesToDisk: false, copiesToClipboard: false, showsQuickAccess: false, opensEditor: true)
        let plan = CaptureDestination.plan(for: .window, settings: settings)
        XCTAssertTrue(plan.writesFile)
        XCTAssertTrue(plan.opensEditor)
    }

    func testClipboardOnlyLeavesNoFileBehind() {
        let settings = CaptureDestination.Settings(
            savesToDisk: false, copiesToClipboard: true, showsQuickAccess: false, opensEditor: false)
        let plan = CaptureDestination.plan(for: .fullscreen, settings: settings)
        XCTAssertFalse(plan.writesFile)
        XCTAssertTrue(plan.writesClipboard)
    }
}
