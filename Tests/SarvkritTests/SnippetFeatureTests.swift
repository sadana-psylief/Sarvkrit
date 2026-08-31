import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The tap-side half of Text Snippets, driven with synthetic `CGEvent`s.
///
/// The matcher's own tests cover matching and the buffer bound. These cover the wiring the matcher
/// can't see: that the feature stands down where it must, and that it doesn't hold on to anything it
/// shouldn't.
final class SnippetFeatureTests: XCTestCase {

    /// - Parameter snippets: the *complete* table. A fresh store ships example snippets, so those
    ///   are cleared first — otherwise "no snippets" would quietly mean "three snippets".
    private func makeFeature(
        _ snippets: [Snippet] = [],
        frontmost: String? = nil
    ) -> SnippetFeature {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippet-\(UUID().uuidString)")
        let store = SnippetStore(directory: directory)
        for example in store.snippets { store.delete(id: example.id) }
        for snippet in snippets { store.add(snippet) }
        return SnippetFeature(
            store: store,
            defaults: UserDefaults(suiteName: "snippets.\(UUID().uuidString)")!,
            frontmostBundleID: { frontmost }
        )
    }

    /// A keyDown that types `character`.
    private func keyDown(_ character: Character, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        let utf16 = Array(String(character).utf16)
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        event.flags = flags
        return event
    }

    private func key(_ keyCode: CGKeyCode, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        return event
    }

    private func swallowed(_ decision: EventDecision) -> Bool {
        if case .swallow = decision { return true }
        return false
    }

    // MARK: - The mask

    func testItSubscribesToWhatItNeedsAndNothingMore() {
        let feature = makeFeature()
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown] {
            XCTAssertNotEqual(feature.eventMask & Sarvkrit.eventMask(type), 0, "\(type) missing")
        }
        // Not mouse drags — nothing here cares where the pointer goes, and `leftMouseDragged`
        // fires at pointer frequency for every drag on the system.
        XCTAssertEqual(feature.eventMask & Sarvkrit.eventMask(.leftMouseDragged), 0)
    }

    // MARK: - Standing down

    func testAnExcludedAppGetsNoExpansion() {
        let feature = makeFeature(
            [Snippet(trigger: ";a", expansion: "X", style: .prefix)],
            frontmost: "com.apple.Terminal"
        )
        feature.excludedBundleIDs = ["com.apple.Terminal"]

        _ = feature.handle(event: keyDown(";"), type: .keyDown)
        let decision = feature.handle(event: keyDown("a"), type: .keyDown)
        XCTAssertFalse(swallowed(decision), "an excluded app must see its own keystrokes")
    }

    func testTheSameSnippetFiresInAnAppThatIsNotExcluded() {
        // The other half: without this, a broken matcher would pass the test above for the wrong
        // reason.
        let feature = makeFeature(
            [Snippet(trigger: ";a", expansion: "X", style: .prefix)],
            frontmost: "com.apple.TextEdit"
        )
        feature.excludedBundleIDs = ["com.apple.Terminal"]

        _ = feature.handle(event: keyDown(";"), type: .keyDown)
        XCTAssertTrue(swallowed(feature.handle(event: keyDown("a"), type: .keyDown)))
    }

    func testTerminalsAndPasswordManagersAreExcludedByDefault() {
        // Not a style preference: a trigger expanding inside a shell command is at best surprising,
        // and a password field is exactly where an expansion must never interfere.
        let feature = makeFeature()
        XCTAssertTrue(feature.excludedBundleIDs.contains("com.apple.Terminal"))
        XCTAssertTrue(feature.excludedBundleIDs.contains("com.googlecode.iterm2"))
        XCTAssertTrue(feature.excludedBundleIDs.contains("com.1password.1password"))
    }

    func testAModifierChordIsNotTyping() {
        let feature = makeFeature([Snippet(trigger: ";a", expansion: "X", style: .prefix)])
        _ = feature.handle(event: keyDown(";"), type: .keyDown)
        // ⌘a in the middle should break the trigger, not extend it.
        _ = feature.handle(event: keyDown("a", flags: .maskCommand), type: .keyDown)
        XCTAssertFalse(swallowed(feature.handle(event: keyDown("a"), type: .keyDown)),
                       "the chord should have cleared the partial trigger")
    }

    func testShiftIsStillTyping() {
        // Shift and caps lock produce characters; only ⌘ ⌃ ⌥ mean "this is a shortcut".
        let feature = makeFeature([Snippet(trigger: ";A", expansion: "X", style: .prefix)])
        _ = feature.handle(event: keyDown(";"), type: .keyDown)
        let decision = feature.handle(event: keyDown("A", flags: .maskShift), type: .keyDown)
        XCTAssertTrue(swallowed(decision), "a shifted character is typing")
    }

    func testCaretMovingKeysBreakTheTrigger() {
        // Return, Tab, Escape, the arrows and both deletes all move the caret somewhere the buffer
        // can't follow.
        for keyCode in [CGKeyCode(36), 48, 53, 51, 117, 123, 124, 125, 126] {
            let feature = makeFeature([Snippet(trigger: ";a", expansion: "X", style: .prefix)])
            _ = feature.handle(event: keyDown(";"), type: .keyDown)
            _ = feature.handle(event: key(keyCode), type: .keyDown)
            XCTAssertFalse(swallowed(feature.handle(event: keyDown("a"), type: .keyDown)),
                           "keycode \(keyCode) should have cleared the buffer")
        }
    }

    func testAClickBreaksTheTrigger() {
        let feature = makeFeature([Snippet(trigger: ";a", expansion: "X", style: .prefix)])
        _ = feature.handle(event: keyDown(";"), type: .keyDown)

        let click = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero,
            mouseButton: .left
        )!
        XCTAssertFalse(swallowed(feature.handle(event: click, type: .leftMouseDown)),
                       "a click is never swallowed")
        XCTAssertFalse(swallowed(feature.handle(event: keyDown("a"), type: .keyDown)),
                       "the click moved the caret, so the trigger is broken")
    }

    // MARK: - Expanding

    func testACompletedTriggerIsSwallowed() {
        // Swallowed, not passed: the trigger's last character must not also reach the app, or it
        // would be left behind after the backspaces.
        let feature = makeFeature([Snippet(trigger: ";a", expansion: "X", style: .prefix)])
        _ = feature.handle(event: keyDown(";"), type: .keyDown)
        XCTAssertTrue(swallowed(feature.handle(event: keyDown("a"), type: .keyDown)))
    }

    func testTheMatchingKeyUpIsSwallowedToo() {
        let feature = makeFeature([Snippet(trigger: ";a", expansion: "X", style: .prefix)])
        _ = feature.handle(event: keyDown(";"), type: .keyDown)
        _ = feature.handle(event: keyDown("a"), type: .keyDown)

        // Same keycode as the swallowed keyDown — 0, since these are unicode-string events.
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
        XCTAssertTrue(swallowed(feature.handle(event: up, type: .keyUp)),
                      "a keyUp whose keyDown the app never saw leaves modifiers confused")
    }

    func testOrdinaryTypingIsNeverSwallowed() {
        let feature = makeFeature([Snippet(trigger: ";addr", expansion: "X", style: .prefix)])
        for character in "the quick brown fox" {
            XCTAssertFalse(swallowed(feature.handle(event: keyDown(character), type: .keyDown)),
                           "‘\(character)’ was swallowed")
        }
    }

    func testWithAnEmptyTableNothingIsEverSwallowed() {
        let feature = makeFeature()
        for character in ";addr;sig;today" {
            XCTAssertFalse(swallowed(feature.handle(event: keyDown(character), type: .keyDown)))
        }
    }

    // MARK: - Nothing reaches disk

    func testTypingNeverWritesToTheSnippetFile() {
        // The guarantee stated in the pane, asserted rather than promised.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippet-\(UUID().uuidString)")
        let store = SnippetStore(directory: directory)
        store.add(Snippet(trigger: ";a", expansion: "X", style: .prefix))
        let feature = SnippetFeature(
            store: store,
            defaults: UserDefaults(suiteName: "snippets.\(UUID().uuidString)")!,
            frontmostBundleID: { "com.apple.TextEdit" }
        )

        let fileURL = directory.appendingPathComponent("snippets.json")
        let before = try? Data(contentsOf: fileURL)

        for character in "hunter2 correct horse battery staple" {
            _ = feature.handle(event: keyDown(character), type: .keyDown)
        }

        let after = try? Data(contentsOf: fileURL)
        XCTAssertEqual(before, after, "typing must not change anything on disk")

        // And what did land on disk must not contain what was typed.
        let contents = String(data: after ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(contents.contains("hunter2"))
        XCTAssertFalse(contents.contains("battery"))
    }

    func testDeactivatingForgetsEverything() {
        let feature = makeFeature([Snippet(trigger: ";a", expansion: "X", style: .prefix)])
        _ = feature.handle(event: keyDown(";"), type: .keyDown)
        feature.deactivate()
        XCTAssertFalse(swallowed(feature.handle(event: keyDown("a"), type: .keyDown)),
                       "state must not survive the feature being switched off")
    }
}
