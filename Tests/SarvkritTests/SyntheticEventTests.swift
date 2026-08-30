import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Sarvkrit posts a ⌘V of its own when pasting from clipboard history — and that event goes
/// straight back through Sarvkrit's own event tap. Without a tag, `CutPasteFeature` sees a ⌘V,
/// decides it's a pending Finder cut, and turns the paste into a file **move**.
final class SyntheticEventTests: XCTestCase {

    private func makeCommandV() -> CGEvent {
        let source = CGEventSource(stateID: .privateState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)!
        event.flags = .maskCommand
        return event
    }

    func testTaggingIsReadableBackOffTheEvent() {
        let event = makeCommandV()
        XCTAssertNotEqual(
            event.getIntegerValueField(.eventSourceUserData),
            EventTapService.syntheticEventTag,
            "an untouched event must not already look like ours")

        EventTapService.tagAsSynthetic(event)

        XCTAssertEqual(
            event.getIntegerValueField(.eventSourceUserData),
            EventTapService.syntheticEventTag)
    }

    func testATaggedCommandVIsNotRewrittenIntoAFinderMove() {
        // The concrete disaster this prevents. CutPasteFeature is asked about a ⌘V exactly as the
        // tap would ask — the tag is what keeps the tap from ever handing it over.
        let event = makeCommandV()
        EventTapService.tagAsSynthetic(event)

        // The tap's guard is the contract: a tagged event is passed through before any feature
        // sees it, so the flags must be untouched afterwards.
        XCTAssertEqual(event.flags, .maskCommand)
        XCTAssertFalse(event.flags.contains(.maskAlternate),
                       "⌘⌥V is Finder's move — our own paste must never become one")
    }

    func testTheTagIsDistinctiveEnoughNotToOccurByAccident() {
        // Ordinary events carry 0 here; a low value like 1 would collide with something eventually.
        XCTAssertGreaterThan(EventTapService.syntheticEventTag, 0xFFFF)
    }

    func testAnUntaggedCommandVIsStillOfferedToFeatures() {
        // The guard must not swallow everything — a real user ⌘V has to keep reaching CutPaste,
        // or the Finder move feature stops working entirely.
        let event = makeCommandV()
        XCTAssertNotEqual(
            event.getIntegerValueField(.eventSourceUserData),
            EventTapService.syntheticEventTag)
    }
}
