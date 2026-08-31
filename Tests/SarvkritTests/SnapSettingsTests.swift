import CoreGraphics
import XCTest
@testable import Sarvkrit

final class SnapSettingsTests: XCTestCase {

    private func settings() -> SnapSettings {
        SnapSettings(defaults: UserDefaults(suiteName: "SnapSettingsTests-\(UUID().uuidString)")!)
    }

    func testSnapByDraggingIsOffUntilAskedFor() {
        // It changes what an ordinary window drag does, which is not something to switch on
        // behind someone's back.
        XCTAssertFalse(settings().snapByDragging)
    }

    func testTheOtherOptionsDefaultOn() {
        // These only matter once snapping is on, and each is the behaviour people expect from it.
        let s = settings()
        XCTAssertTrue(s.restoreSizeOnUnsnap)
        XCTAssertTrue(s.hapticFeedback)
        XCTAssertTrue(s.animateFootprint)
    }

    func testAnUnconfiguredZoneFollowsTheDisplay() {
        // The default is not a fixed action: it resolves per screen, so one setting suits a laptop
        // and an ultrawide at once.
        let s = settings()
        XCTAssertEqual(s.action(for: .left, ultrawide: false), .leftHalf)
        XCTAssertEqual(s.action(for: .left, ultrawide: true), .firstThird)
        XCTAssertNil(s.customAction(for: .left))
    }

    func testAnExplicitChoiceOverridesBothDisplayKinds() {
        let s = settings()
        s.setAction(.maximize, for: .left)
        XCTAssertEqual(s.action(for: .left, ultrawide: false), .maximize)
        XCTAssertEqual(s.action(for: .left, ultrawide: true), .maximize)
    }

    func testClearingAZoneReturnsItToTheDisplayDefault() {
        let s = settings()
        s.setAction(.maximize, for: .left)
        s.setAction(nil, for: .left)
        XCTAssertEqual(s.action(for: .left, ultrawide: true), .firstThird)
    }

    func testOnlyChangedZonesArePersisted() {
        // Storing every default would freeze them at whatever they were when the pane was first
        // opened, so a later change to the defaults would never reach an existing user.
        let suite = "SnapSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = SnapSettings(defaults: defaults)
        first.setAction(.maximize, for: .top)

        let second = SnapSettings(defaults: defaults)
        XCTAssertEqual(second.customAction(for: .top), .maximize)
        XCTAssertNil(second.customAction(for: .left), "untouched zones stay on the default")
        XCTAssertEqual(second.action(for: .left, ultrawide: true), .firstThird)
    }

    func testOptionsSurviveARestart() {
        let suite = "SnapSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = SnapSettings(defaults: defaults)
        first.snapByDragging = true
        first.hapticFeedback = false

        let second = SnapSettings(defaults: defaults)
        XCTAssertTrue(second.snapByDragging)
        XCTAssertFalse(second.hapticFeedback)
    }

    func testResetClearsEveryCustomZone() {
        let s = settings()
        s.setAction(.maximize, for: .left)
        s.setAction(.center, for: .top)
        s.resetZones()
        XCTAssertNil(s.customAction(for: .left))
        XCTAssertNil(s.customAction(for: .top))
    }

    func testAStoredZoneFromAFutureVersionIsIgnoredNotFatal() {
        // A downgrade after a release adds actions must not wipe the zones the user did set.
        let suite = "SnapSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["left": "someActionFromTheFuture", "top": "maximize"],
                     forKey: "windows.snapZones")

        let s = SnapSettings(defaults: defaults)
        XCTAssertEqual(s.customAction(for: .top), .maximize)
        XCTAssertNil(s.customAction(for: .left))
    }

    // MARK: - The event mask

    func testTheTapOnlyListensForDragsWhenSnappingIsOn() {
        // `leftMouseDragged` fires at pointer frequency for every drag on the system. Subscribing
        // to it when the feature can't use it would be a standing cost for nothing.
        let feature = WindowFeature(
            defaults: UserDefaults(suiteName: "SnapSettingsTests-\(UUID().uuidString)")!
        )
        let dragBit = Sarvkrit.eventMask(.leftMouseDragged)

        feature.setSnapByDragging(false)
        XCTAssertEqual(feature.eventMask & dragBit, 0, "must not listen while the option is off")

        feature.setSnapByDragging(true)
        XCTAssertNotEqual(feature.eventMask & dragBit, 0)
    }

    func testKeyboardEventsAreSubscribedEitherWay() {
        let feature = WindowFeature(
            defaults: UserDefaults(suiteName: "SnapSettingsTests-\(UUID().uuidString)")!
        )
        XCTAssertNotEqual(feature.eventMask & Sarvkrit.eventMask(.keyDown), 0)
        XCTAssertNotEqual(feature.eventMask & Sarvkrit.eventMask(.keyUp), 0)
    }
}
