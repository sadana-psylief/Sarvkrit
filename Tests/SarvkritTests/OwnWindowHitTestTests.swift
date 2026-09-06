import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Recognising our own windows before asking Accessibility about a point.
///
/// **This is a crash, not a nicety.** `AXUIElementCopyElementAtPosition` is served *in-process*
/// when the point is over one of our own windows — AppKit answers it synchronously on the calling
/// thread, routing through `NSHostingView.accessibilityHitTest` into SwiftUI, which evaluates a
/// view body and asserts it is on the main actor. Both callers do that hit-test on a background
/// queue, deliberately and correctly, because it costs up to four Accessibility round trips.
///
/// Both callers also already tried to skip our own process — and could not, because the check reads
/// the PID of an element that the crashing call was supposed to return. The guard has to happen
/// *before* the question is asked, which means answering it without Accessibility at all.
final class OwnWindowHitTestTests: XCTestCase {

    private func window(pid: pid_t, x: CGFloat, y: CGFloat,
                        width: CGFloat, height: CGFloat) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowBounds as String: [
            "X": x, "Y": y, "Width": width, "Height": height,
         ] as [String: Any]]
    }

    func testAPointOverOneOfOurWindowsIsRecognised() {
        let windows = [window(pid: 42, x: 100, y: 100, width: 400, height: 300)]
        XCTAssertTrue(AX.isPoint(CGPoint(x: 200, y: 200), overWindowsOf: 42, in: windows))
    }

    func testAPointOverAnotherAppsWindowIsNot() {
        let windows = [window(pid: 99, x: 100, y: 100, width: 400, height: 300)]
        XCTAssertFalse(AX.isPoint(CGPoint(x: 200, y: 200), overWindowsOf: 42, in: windows))
    }

    func testAPointOutsideEveryWindowIsNot() {
        let windows = [window(pid: 42, x: 100, y: 100, width: 400, height: 300)]
        XCTAssertFalse(AX.isPoint(CGPoint(x: 900, y: 900), overWindowsOf: 42, in: windows))
    }

    /// The window list is front-to-back and holds every app; ours may be anywhere in it.
    func testOursIsFoundBehindAnotherAppsEntry() {
        let windows = [window(pid: 99, x: 0, y: 0, width: 50, height: 50),
                       window(pid: 42, x: 100, y: 100, width: 400, height: 300)]
        XCTAssertTrue(AX.isPoint(CGPoint(x: 200, y: 200), overWindowsOf: 42, in: windows))
    }

    /// Both spaces are top-left origin with y increasing downwards — `kCGWindowBounds` and the
    /// coordinates `AXUIElementCopyElementAtPosition` takes agree, which is the only reason this
    /// substitution is sound.
    func testTheEdgesBelongToTheWindow() {
        let windows = [window(pid: 42, x: 100, y: 100, width: 400, height: 300)]
        XCTAssertTrue(AX.isPoint(CGPoint(x: 100, y: 100), overWindowsOf: 42, in: windows))
        XCTAssertFalse(AX.isPoint(CGPoint(x: 500.5, y: 400.5), overWindowsOf: 42, in: windows))
    }

    func testAnEmptyListIsSafe() {
        XCTAssertFalse(AX.isPoint(.zero, overWindowsOf: 42, in: []))
    }

    /// A malformed entry must not be read as a match — that would disable the snap hit-test
    /// everywhere rather than only over our own windows.
    func testAnEntryWithNoBoundsIsIgnored() {
        let windows: [[String: Any]] = [[kCGWindowOwnerPID as String: NSNumber(value: 42)]]
        XCTAssertFalse(AX.isPoint(CGPoint(x: 10, y: 10), overWindowsOf: 42, in: windows))
    }

    func testAnEntryWithNoOwnerIsIgnored() {
        let windows: [[String: Any]] = [[kCGWindowBounds as String:
            ["X": 0.0, "Y": 0.0, "Width": 100.0, "Height": 100.0] as [String: Any]]]
        XCTAssertFalse(AX.isPoint(CGPoint(x: 10, y: 10), overWindowsOf: 42, in: windows))
    }
}
