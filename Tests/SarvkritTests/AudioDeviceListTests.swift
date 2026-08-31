import CoreAudio
import XCTest
@testable import Sarvkrit

/// Choosing between audio devices. Pure, so the cases you'd otherwise only meet by pulling cables
/// at the wrong moment are a table instead.
final class AudioDeviceListTests: XCTestCase {

    private func device(
        _ id: AudioObjectID,
        _ name: String,
        uid: String? = nil,
        output: Bool = true,
        input: Bool = false,
        aggregate: Bool = false
    ) -> AudioDevice {
        AudioDevice(
            id: id, uid: uid ?? "uid-\(id)", name: name,
            hasOutput: output, hasInput: input, isAggregate: aggregate
        )
    }

    private lazy var speakers = device(1, "MacBook Pro Speakers")
    private lazy var headphones = device(2, "AirPods Pro")
    private lazy var display = device(3, "Studio Display")
    private lazy var mic = device(4, "MacBook Pro Microphone", output: false, input: true)

    // MARK: - What gets offered

    func testOnlyDevicesOfTheRightKindAreOffered() {
        let all = [speakers, headphones, mic]
        XCTAssertEqual(
            AudioDeviceList.selectable(from: all, kind: .output).map(\.name),
            ["AirPods Pro", "MacBook Pro Speakers"]
        )
        XCTAssertEqual(
            AudioDeviceList.selectable(from: all, kind: .input).map(\.name),
            ["MacBook Pro Microphone"]
        )
    }

    func testAggregatesAreNeverOffered() {
        // Other audio tools create these. Switching someone's output to a private aggregate that
        // another app is driving is a good way to break their setup.
        let aggregate = device(9, "BlackHole 2ch", aggregate: true)
        let options = AudioDeviceList.selectable(from: [speakers, aggregate], kind: .output)
        XCTAssertEqual(options.map(\.name), ["MacBook Pro Speakers"])
    }

    func testTheOrderIsStableAndCaseInsensitive() {
        // A list that reshuffles between openings is unusable, and cycling would be unpredictable.
        let devices = [device(1, "zoom audio"), device(2, "AirPods"), device(3, "Built-in")]
        XCTAssertEqual(
            AudioDeviceList.selectable(from: devices, kind: .output).map(\.name),
            ["AirPods", "Built-in", "zoom audio"]
        )
    }

    func testADeviceThatIsBothInputAndOutputAppearsInBoth() {
        let both = device(5, "Studio Display", output: true, input: true)
        XCTAssertEqual(AudioDeviceList.selectable(from: [both], kind: .output).count, 1)
        XCTAssertEqual(AudioDeviceList.selectable(from: [both], kind: .input).count, 1)
    }

    // MARK: - Cycling

    func testCyclingAdvancesInOrder() {
        let all = [speakers, headphones, display]   // sorted: AirPods, MacBook, Studio
        XCTAssertEqual(AudioDeviceList.next(after: 2, in: all, kind: .output)?.name, "MacBook Pro Speakers")
        XCTAssertEqual(AudioDeviceList.next(after: 1, in: all, kind: .output)?.name, "Studio Display")
    }

    func testCyclingWrapsAround() {
        let all = [speakers, headphones, display]
        XCTAssertEqual(AudioDeviceList.next(after: 3, in: all, kind: .output)?.name, "AirPods Pro")
    }

    func testCyclingFromADeviceThatHasBeenUnpluggedStartsAtTheTop() {
        // The awkward one: the shortcut is pressed just after the current device vanished, so
        // there's no position to advance from. Refusing would leave the user stuck on nothing.
        let all = [speakers, headphones]
        XCTAssertEqual(AudioDeviceList.next(after: 99, in: all, kind: .output)?.name, "AirPods Pro")
    }

    func testCyclingWithOnlyOneDeviceGoesNowhere() {
        // Nothing to switch to; the shortcut should do nothing rather than something surprising.
        XCTAssertNil(AudioDeviceList.next(after: 1, in: [speakers], kind: .output))
    }

    func testCyclingWithOneDeviceThatIsNotCurrentSelectsIt() {
        // Only one option and we're not on it — that's a switch worth making.
        XCTAssertEqual(AudioDeviceList.next(after: 99, in: [speakers], kind: .output)?.name,
                       "MacBook Pro Speakers")
    }

    func testCyclingWithNoDevicesIsHarmless() {
        XCTAssertNil(AudioDeviceList.next(after: nil, in: [], kind: .output))
    }

    func testCyclingIgnoresTheOtherKind() {
        // A microphone must never appear in the output cycle.
        let all = [speakers, mic]
        XCTAssertEqual(AudioDeviceList.next(after: 1, in: all, kind: .output)?.name, nil)
    }

    func testCyclingEventuallyVisitsEveryDevice() {
        let all = [speakers, headphones, display]
        var seen: Set<String> = []
        var current: AudioObjectID? = 1
        for _ in 0..<3 {
            guard let next = AudioDeviceList.next(after: current, in: all, kind: .output) else { break }
            seen.insert(next.name)
            current = next.id
        }
        XCTAssertEqual(seen.count, 3, "cycling should reach all three")
    }

    // MARK: - The preferred device

    func testThePreferredDeviceIsMatchedByUidNotID() {
        // The reason this matters: an AudioObjectID is reassigned on reconnect. Matching on it
        // would mean auto-switching to whatever device happens to hold that number now.
        let reconnected = device(77, "AirPods Pro", uid: "uid-2")
        let found = AudioDeviceList.preferred(uid: "uid-2", in: [speakers, reconnected], kind: .output)
        XCTAssertEqual(found?.id, 77, "found by uid despite a different object ID")
    }

    func testAPreferredDeviceThatIsNotConnectedIsNotFound() {
        XCTAssertNil(AudioDeviceList.preferred(uid: "uid-gone", in: [speakers], kind: .output))
    }

    func testNoPreferenceMeansNoPreferredDevice() {
        XCTAssertNil(AudioDeviceList.preferred(uid: nil, in: [speakers], kind: .output))
    }

    // MARK: - Auto-switching

    func testAutoSwitchFiresWhenThePreferredDeviceAppears() {
        let target = AudioDeviceList.shouldAutoSwitch(
            to: "uid-2", current: 1, devices: [speakers, headphones], kind: .output
        )
        XCTAssertEqual(target?.name, "AirPods Pro")
    }

    func testAutoSwitchDoesNothingIfAlreadyOnThatDevice() {
        // Otherwise every unrelated device change would re-set the same default.
        XCTAssertNil(AudioDeviceList.shouldAutoSwitch(
            to: "uid-2", current: 2, devices: [speakers, headphones], kind: .output
        ))
    }

    func testAutoSwitchDoesNothingWhenThePreferredDeviceIsAbsent() {
        XCTAssertNil(AudioDeviceList.shouldAutoSwitch(
            to: "uid-2", current: 1, devices: [speakers], kind: .output
        ))
    }

    func testAutoSwitchDoesNothingWithNoPreference() {
        XCTAssertNil(AudioDeviceList.shouldAutoSwitch(
            to: nil, current: 1, devices: [speakers, headphones], kind: .output
        ))
    }

    func testAutoSwitchWillNotChooseAnAggregate() {
        // Even if somehow set as the preference — the filter applies here too.
        let aggregate = device(9, "BlackHole 2ch", uid: "uid-agg", aggregate: true)
        XCTAssertNil(AudioDeviceList.shouldAutoSwitch(
            to: "uid-agg", current: 1, devices: [speakers, aggregate], kind: .output
        ))
    }
}
