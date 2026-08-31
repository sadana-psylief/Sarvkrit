import AppKit
import XCTest
@testable import Sarvkrit

final class MenuBarIconStateTests: XCTestCase {

    // MARK: - The truth table

    func testIdleShowsTheOrdinaryIcon() {
        XCTAssertEqual(
            MenuBarIconState.current(keepAwakeRunning: false, systemSleepDisabled: false), .idle)
        XCTAssertEqual(MenuBarIconState.idle.symbolName, "command.square")
    }

    func testKeepAwakeShowsTheCup() {
        XCTAssertEqual(
            MenuBarIconState.current(keepAwakeRunning: true, systemSleepDisabled: false), .awake)
    }

    func testSystemSleepDisabledShowsTheBolt() {
        XCTAssertEqual(
            MenuBarIconState.current(keepAwakeRunning: true, systemSleepDisabled: true),
            .systemSleepDisabled,
            "the more serious state is the one to show")
    }

    func testAStrandedFlagStillShowsTheBoltEvenThoughTheFeatureIsOff() {
        // The case the indicator exists for: a reboot left sleep disabled, the toggle reads off,
        // and the user has no other way to find out why their Mac won't sleep.
        XCTAssertEqual(
            MenuBarIconState.current(keepAwakeRunning: false, systemSleepDisabled: true),
            .systemSleepDisabled)
    }

    // MARK: - Symbols must actually exist

    func testEverySymbolResolvesOnThisSystem() {
        // A missing SF Symbol draws nothing at all — it looks like a broken icon rather than
        // raising an error, so it would ship unnoticed.
        for state in [MenuBarIconState.idle, .awake, .systemSleepDisabled] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil),
                "\(state.symbolName) does not exist")
        }
    }

    func testEveryStateIsDescribedForVoiceOver() {
        for state in [MenuBarIconState.idle, .awake, .systemSleepDisabled] {
            XCTAssertFalse(state.accessibilityLabel.isEmpty)
        }
    }

    func testTheThreeStatesLookDifferent() {
        // Two states sharing a glyph would make the indicator useless.
        let symbols = Set([MenuBarIconState.idle, .awake, .systemSleepDisabled].map(\.symbolName))
        XCTAssertEqual(symbols.count, 3)
    }

    // MARK: - Countdown

    func testCountdownIsWholeMinutes() {
        XCTAssertEqual(MenuBarIconState.countdownText(remaining: 28 * 60), "28m")
        XCTAssertEqual(MenuBarIconState.countdownText(remaining: 90 * 60), "90m")
        XCTAssertEqual(MenuBarIconState.countdownText(remaining: 61), "1m")
    }

    func testTheLastMinuteReadsLessThanOne() {
        // "0m" would sit there looking stuck for a full minute.
        XCTAssertEqual(MenuBarIconState.countdownText(remaining: 59), "<1m")
        XCTAssertEqual(MenuBarIconState.countdownText(remaining: 1), "<1m")
    }

    func testNothingIsShownWithoutATimer() {
        XCTAssertNil(MenuBarIconState.countdownText(remaining: nil), "indefinite has nothing to count")
        XCTAssertNil(MenuBarIconState.countdownText(remaining: 0))
        XCTAssertNil(MenuBarIconState.countdownText(remaining: -5), "an expired timer shows nothing")
    }

    // MARK: - Panel header

    func testTheHeaderSaysWhatIsHappening() {
        XCTAssertEqual(MenuBarIconState.statusLine(state: .awake, remaining: 28 * 60), "Awake · 28m left")
        XCTAssertEqual(
            MenuBarIconState.statusLine(state: .systemSleepDisabled, remaining: nil),
            "Sleep disabled")
        XCTAssertEqual(MenuBarIconState.statusLine(state: .awake, remaining: nil), "Awake")
    }

    func testTheHeaderSaysNothingWhenIdle() {
        XCTAssertNil(MenuBarIconState.statusLine(state: .idle, remaining: nil))
        XCTAssertNil(MenuBarIconState.statusLine(state: .idle, remaining: 600),
                     "a leftover countdown must not resurrect the header")
    }

    // MARK: - The microphone outranks everything

    func testAMutedMicrophoneWinsOverEverySleepState() {
        // Deliberate precedence: not noticing a muted mic costs you immediately and personally,
        // where sleep behaviour does not.
        XCTAssertEqual(
            MenuBarIconState.current(
                keepAwakeRunning: true, systemSleepDisabled: true, microphoneMuted: true),
            .microphoneMuted
        )
        XCTAssertEqual(
            MenuBarIconState.current(
                keepAwakeRunning: false, systemSleepDisabled: false, microphoneMuted: true),
            .microphoneMuted
        )
    }

    func testTheSleepStatesAreUnchangedWhenTheMicIsLive() {
        // Adding a state must not disturb the existing ordering.
        XCTAssertEqual(
            MenuBarIconState.current(
                keepAwakeRunning: true, systemSleepDisabled: true, microphoneMuted: false),
            .systemSleepDisabled
        )
        XCTAssertEqual(
            MenuBarIconState.current(
                keepAwakeRunning: true, systemSleepDisabled: false, microphoneMuted: false),
            .awake
        )
        XCTAssertEqual(
            MenuBarIconState.current(
                keepAwakeRunning: false, systemSleepDisabled: false, microphoneMuted: false),
            .idle
        )
    }

    func testMicMuteDefaultsToOffSoExistingCallersAreUnaffected() {
        XCTAssertEqual(
            MenuBarIconState.current(keepAwakeRunning: true, systemSleepDisabled: false),
            .awake
        )
    }

    func testTheMutedStateHasItsOwnSymbolAndSpokenLabel() {
        XCTAssertEqual(MenuBarIconState.microphoneMuted.symbolName, "mic.slash.fill")
        XCTAssertTrue(
            MenuBarIconState.microphoneMuted.accessibilityLabel.contains("microphone muted"),
            "the icon conveys nothing to VoiceOver without this"
        )
    }

    func testTheMutedStateShowsAStatusLineWithNoCountdown() {
        // There is nothing counting down, so it must not render "· 0m left".
        XCTAssertEqual(
            MenuBarIconState.statusLine(state: .microphoneMuted, remaining: nil), "Mic muted")
        XCTAssertEqual(
            MenuBarIconState.statusLine(state: .microphoneMuted, remaining: 300), "Mic muted")
    }

    // MARK: - The camera outranks even a muted mic

    func testAnActiveCameraWinsOverEverything() {
        // The order is a judgement: a muted mic is a safety measure already working, while a camera
        // that is on is a live exposure the user may not have noticed.
        XCTAssertEqual(
            MenuBarIconState.current(
                keepAwakeRunning: true, systemSleepDisabled: true,
                microphoneMuted: true, cameraOn: true),
            .cameraOn
        )
    }

    func testTheRestOfTheOrderIsUndisturbedByTheCameraCase() {
        // Adding a state at the top must not shuffle anything below it.
        XCTAssertEqual(
            MenuBarIconState.current(
                keepAwakeRunning: true, systemSleepDisabled: true,
                microphoneMuted: true, cameraOn: false),
            .microphoneMuted
        )
        XCTAssertEqual(
            MenuBarIconState.current(
                keepAwakeRunning: true, systemSleepDisabled: true,
                microphoneMuted: false, cameraOn: false),
            .systemSleepDisabled
        )
        XCTAssertEqual(
            MenuBarIconState.current(
                keepAwakeRunning: true, systemSleepDisabled: false,
                microphoneMuted: false, cameraOn: false),
            .awake
        )
    }

    func testTheCameraDefaultsToOffSoOlderCallersAreUnaffected() {
        XCTAssertEqual(
            MenuBarIconState.current(
                keepAwakeRunning: false, systemSleepDisabled: false, microphoneMuted: true),
            .microphoneMuted
        )
    }

    func testTheCameraStateHasItsOwnSymbolAndSpokenLabel() {
        XCTAssertEqual(MenuBarIconState.cameraOn.symbolName, "video.fill")
        XCTAssertTrue(
            MenuBarIconState.cameraOn.accessibilityLabel.lowercased().contains("camera"),
            "the icon says nothing to VoiceOver without this"
        )
    }

    func testTheCameraStatusLineCarriesNoCountdown() {
        XCTAssertEqual(MenuBarIconState.statusLine(state: .cameraOn, remaining: nil), "Camera on")
        XCTAssertEqual(MenuBarIconState.statusLine(state: .cameraOn, remaining: 300), "Camera on")
    }
}
