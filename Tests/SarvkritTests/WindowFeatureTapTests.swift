import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The tap-side half of window management, driven with synthetic `CGEvent`s.
///
/// Everything here fails *silently* in use — a swallowed key simply never arrives — so it is worth
/// pinning rather than checking by hand.
final class WindowFeatureTapTests: XCTestCase {

    private func event(_ keyCode: Int64, down: Bool, flags: CGEventFlags, isRepeat: Bool = false)
        -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down
        )!
        event.flags = flags
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return event
    }

    private let bound: CGEventFlags = [.maskControl, .maskAlternate]
    private let leftArrow: Int64 = 123

    // MARK: - Matching

    func testABoundShortcutIsSwallowed() {
        // Swallowed, not passed: the app behind must not also receive ⌃⌥←.
        let feature = WindowFeature()
        let decision = feature.handle(event: event(leftArrow, down: true, flags: bound), type: .keyDown)
        if case .pass = decision { XCTFail("a bound shortcut should be swallowed") }
    }

    func testAnUnboundKeyPassesThrough() {
        let feature = WindowFeature()
        let decision = feature.handle(event: event(0, down: true, flags: []), type: .keyDown)
        guard case .pass = decision else { return XCTFail("ordinary typing must not be touched") }
    }

    func testTheWrongModifiersPassThrough() {
        // ⌃⌥⇧← belongs to someone else.
        let feature = WindowFeature()
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
        guard case .pass = feature.handle(event: event(leftArrow, down: true, flags: flags),
                                          type: .keyDown)
        else { return XCTFail("an exact-match failure must pass through") }
    }

    // MARK: - keyUp pairing

    func testTheMatchingKeyUpIsSwallowedToo() {
        // A keyUp arriving for a keyDown the app never saw leaves its modifier state confused.
        let feature = WindowFeature()
        _ = feature.handle(event: event(leftArrow, down: true, flags: bound), type: .keyDown)

        let up = feature.handle(event: event(leftArrow, down: false, flags: bound), type: .keyUp)
        if case .pass = up { XCTFail("the paired keyUp should be swallowed") }
    }

    func testAnUnpairedKeyUpPassesThrough() {
        let feature = WindowFeature()
        guard case .pass = feature.handle(event: event(leftArrow, down: false, flags: bound),
                                          type: .keyUp)
        else { return XCTFail("a keyUp we never swallowed the down for must pass") }
    }

    func testEachKeyUpIsSwallowedOnlyOnce() {
        let feature = WindowFeature()
        _ = feature.handle(event: event(leftArrow, down: true, flags: bound), type: .keyDown)
        _ = feature.handle(event: event(leftArrow, down: false, flags: bound), type: .keyUp)

        guard case .pass = feature.handle(event: event(leftArrow, down: false, flags: bound),
                                          type: .keyUp)
        else { return XCTFail("the second keyUp is a different press and must pass") }
    }

    // MARK: - Recording

    func testTheTapStandsDownWhileRecording() {
        // The trap: recording a combination that is already bound — which is most of them, since
        // the recorder is usually used to *change* a binding — would otherwise snap a window while
        // the user was trying to type it.
        let feature = WindowFeature()
        feature.isRecording = true

        guard case .pass = feature.handle(event: event(leftArrow, down: true, flags: bound),
                                          type: .keyDown)
        else { return XCTFail("a bound shortcut must reach the recorder untouched") }
    }

    func testMatchingResumesWhenRecordingEnds() {
        let feature = WindowFeature()
        feature.isRecording = true
        _ = feature.handle(event: event(leftArrow, down: true, flags: bound), type: .keyDown)
        feature.isRecording = false

        let decision = feature.handle(event: event(leftArrow, down: true, flags: bound), type: .keyDown)
        if case .pass = decision { XCTFail("the shortcut should work again once recording ends") }
    }

    func testAPendingKeyUpIsStillDrainedWhenRecordingStartsMidPress() {
        // Shortcut pressed, then the recorder opens before the key comes back up. Releasing that
        // keyUp into the app leaves a modifier stuck down.
        let feature = WindowFeature()
        _ = feature.handle(event: event(leftArrow, down: true, flags: bound), type: .keyDown)
        feature.isRecording = true

        let up = feature.handle(event: event(leftArrow, down: false, flags: bound), type: .keyUp)
        if case .pass = up { XCTFail("the orphaned keyUp should still be swallowed") }
    }

    // MARK: - Autorepeat

    func testHeldKeysAreStillSwallowedWhileRepeating() {
        // Letting repeats through would type into the app behind.
        let feature = WindowFeature()
        _ = feature.handle(event: event(leftArrow, down: true, flags: bound), type: .keyDown)

        let repeated = feature.handle(
            event: event(leftArrow, down: true, flags: bound, isRepeat: true), type: .keyDown
        )
        if case .pass = repeated { XCTFail("repeats of a swallowed key must not escape") }
    }

    func testDeactivationForgetsPendingKeys() {
        let feature = WindowFeature()
        _ = feature.handle(event: event(leftArrow, down: true, flags: bound), type: .keyDown)
        feature.deactivate()

        guard case .pass = feature.handle(event: event(leftArrow, down: false, flags: bound),
                                          type: .keyUp)
        else { return XCTFail("state should not survive the feature being switched off") }
    }
}
