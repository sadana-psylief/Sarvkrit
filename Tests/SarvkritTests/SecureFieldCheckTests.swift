import XCTest
@testable import Sarvkrit

/// The secure-field check, which is what keeps somebody's password out of `events.json`.
///
/// It used to reach the element with `unsafeBitCast`, doing no type check where every other
/// Accessibility call site in this codebase does one. That was not the crash it was once blamed
/// for — the crash report named a blocked main thread instead — but an unchecked cast of a
/// `CFTypeRef` is a bug waiting for the day the attribute comes back as something else.
final class SecureFieldCheckTests: XCTestCase {

    /// Callable repeatedly, from a background thread, without tripping over itself. The keystroke
    /// path runs it once per key, wherever AppKit delivered the event.
    func testRepeatedCallsAreStableOffTheMainThread() {
        let done = expectation(description: "checked")
        DispatchQueue.global().async {
            for _ in 0..<200 { _ = SecureFieldCheck.isFocusedElementSecure() }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    /// With nothing focused — which is the ordinary case in a test host — the answer is "not
    /// secure" rather than a crash or a true that would silently stop recording keystrokes.
    func testUnfocusedHostIsNotReportedSecure() {
        XCTAssertFalse(SecureFieldCheck.isFocusedElementSecure())
    }
}
