import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The keystroke hot path, measured directly.
///
/// `CutPasteFeature.handle` runs inside a `.defaultTap` on the main thread for **every key pressed
/// anywhere on the Mac**, so its cost for an ordinary, uninteresting keystroke is the number that
/// matters — not its cost for ⌘X, which happens a few times a minute.
///
/// Constructing a `CGEvent` needs no permission (only *posting* one does), so this runs headless.
final class CutPasteFeaturePerformanceTests: XCTestCase {
    private static let iterations = 10_000

    /// Virtual keycode 0 is "a": no modifiers, not X or V. The overwhelmingly common case.
    private func makeOrdinaryKeystroke() -> CGEvent {
        let source = CGEventSource(stateID: .privateState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)!
        event.flags = []
        return event
    }

    /// Deliberately not `measure { }`. XCTest fails that on wall-clock *variance*, which on a
    /// busy machine is noise rather than regression — a flaky test is worse than no test.
    ///
    /// Instead: take the best of several runs (the minimum filters scheduler noise far better than
    /// a mean) and assert a ceiling generous enough never to trip on load, but far below the
    /// ~900ns/key this cost when it did an `NSWorkspace` lookup per keystroke. Re-introducing any
    /// cross-process call here would blow through it by an order of magnitude.
    func testOrdinaryKeystrokeIsCheap() {
        let feature = CutPasteFeature()
        let event = makeOrdinaryKeystroke()

        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<Self.iterations {
                _ = feature.handle(event: event, type: .keyDown)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
            best = min(best, elapsed)
        }

        let nanosecondsPerKeystroke = best / Double(Self.iterations)
        print("keystroke hot path: \(String(format: "%.0f", nanosecondsPerKeystroke))ns per key")

        XCTAssertLessThan(
            nanosecondsPerKeystroke, 3_000,
            "the keystroke fast path regressed — most likely an IPC call crept back in"
        )
    }

    /// Correctness guard alongside the benchmark: an ordinary keystroke must pass through
    /// untouched, whatever the fast path does.
    func testOrdinaryKeystrokeIsNotModified() {
        let feature = CutPasteFeature()
        let event = makeOrdinaryKeystroke()

        let decision = feature.handle(event: event, type: .keyDown)

        guard case .pass = decision else { return XCTFail("ordinary keystroke must pass through") }
        XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
        XCTAssertEqual(event.flags, [])
    }
}
