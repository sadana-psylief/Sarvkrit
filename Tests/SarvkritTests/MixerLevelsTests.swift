import XCTest
@testable import Sarvkrit

/// Per-app volumes and what counts as having set one.
final class MixerLevelsTests: XCTestCase {

    private func levels() -> MixerLevels {
        MixerLevels(defaults: UserDefaults(suiteName: "mixer-\(UUID().uuidString)")!)
    }

    func testAnAppWithNoLevelSetPlaysAtFullVolume() {
        // The important default. An app the user has never touched must never be quieter than it
        // would have been without this feature installed.
        XCTAssertEqual(levels().level(for: "com.apple.Safari"), 1)
    }

    func testSettingALevelIsRememberedAndReadBack() {
        var l = levels()
        l.setLevel(0.4, for: "com.slack")
        XCTAssertEqual(l.level(for: "com.slack"), 0.4)
        XCTAssertTrue(l.hasCustomLevel(for: "com.slack"))
    }

    func testFullVolumeIsTheAbsenceOfASettingNotASetting() {
        // Otherwise the "apps you've changed" list fills up with apps you set back to normal, and
        // every one of them gets pointlessly routed through a tap.
        var l = levels()
        l.setLevel(0.4, for: "com.slack")
        l.setLevel(1, for: "com.slack")
        XCTAssertFalse(l.hasCustomLevel(for: "com.slack"))
        XCTAssertEqual(l.level(for: "com.slack"), 1)
    }

    func testLevelsAreClamped() {
        var l = levels()
        l.setLevel(-0.5, for: "a")
        XCTAssertEqual(l.level(for: "a"), 0)
        l.setLevel(3, for: "b")
        XCTAssertEqual(l.level(for: "b"), 1)
        XCTAssertFalse(l.hasCustomLevel(for: "b"), "clamped to full, so not a custom level")
    }

    func testZeroIsARealSetting() {
        // Silencing an app is a legitimate thing to want, and must not be confused with "unset".
        var l = levels()
        l.setLevel(0, for: "com.noisy")
        XCTAssertTrue(l.hasCustomLevel(for: "com.noisy"))
        XCTAssertEqual(l.level(for: "com.noisy"), 0)
    }

    func testResettingRemovesTheLevel() {
        var l = levels()
        l.setLevel(0.3, for: "com.slack")
        l.reset("com.slack")
        XCTAssertFalse(l.hasCustomLevel(for: "com.slack"))
        XCTAssertEqual(l.level(for: "com.slack"), 1)
    }

    func testResettingEverythingClearsTheList() {
        var l = levels()
        l.setLevel(0.3, for: "a")
        l.setLevel(0.6, for: "b")
        l.resetAll()
        XCTAssertTrue(l.levels.isEmpty)
    }

    func testLevelsSurviveARestart() {
        // Persistence by bundle ID is the point: a pid means nothing once the app restarts.
        let suite = "mixer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var first = MixerLevels(defaults: defaults)
        first.setLevel(0.42, for: "com.slack")

        let second = MixerLevels(defaults: defaults)
        XCTAssertEqual(second.level(for: "com.slack"), 0.42, accuracy: 0.001)
    }

    func testResettingSomethingNeverSetIsHarmless() {
        var l = levels()
        l.reset("com.never")
        XCTAssertTrue(l.levels.isEmpty)
    }
}
