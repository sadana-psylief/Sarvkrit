import CoreAudio
import XCTest
@testable import Sarvkrit

/// Does the Core Audio layer actually talk to the machine?
///
/// **These touch real hardware**, unlike everything else in this suite, and that is the point.
/// `AudioDeviceListTests` proves the *choosing* is right against synthetic devices; this proves the
/// reading works at all. Twice in this project a layer compiled cleanly, looked right, and did
/// nothing — so "it builds" is not the same as "it works", and every Mac has at least a speaker and
/// a microphone to assert against.
///
/// If these ever fail on a machine with working audio, the wrapper is broken, not the test.
final class AudioSystemSmokeTests: XCTestCase {

    func testTheMachineReportsItsDevices() {
        let devices = AudioSystem.devices()
        XCTAssertFalse(devices.isEmpty, "a Mac with working audio always has devices")
    }

    func testEveryDeviceHasAUidAndAName() {
        // A device missing either would be unusable in the list and unstorable as a preference.
        for device in AudioSystem.devices() {
            XCTAssertFalse(device.uid.isEmpty, "device \(device.id) has no uid")
            XCTAssertFalse(device.name.isEmpty, "device \(device.id) has no name")
        }
    }

    func testThereIsAtLeastOneOutputDevice() {
        let outputs = AudioDeviceList.selectable(from: AudioSystem.devices(), kind: .output)
        XCTAssertFalse(outputs.isEmpty, "every Mac has speakers")
    }

    func testTheDefaultOutputDeviceIsOneOfTheDevicesWeFound() {
        // The join that matters: if scope detection or enumeration is wrong, the current device
        // won't appear in the list and the tray would show nothing ticked.
        guard let current = AudioSystem.defaultDevice(.output) else {
            return XCTFail("no default output device")
        }
        let known = AudioSystem.devices().map(\.id)
        XCTAssertTrue(known.contains(current), "the default output isn't in the enumerated list")
    }

    func testTheDefaultInputDeviceIsOneOfTheDevicesWeFound() throws {
        guard let current = AudioSystem.defaultDevice(.input) else {
            throw XCTSkip("no input device on this machine")
        }
        XCTAssertTrue(AudioSystem.devices().map(\.id).contains(current))
    }

    func testScopeDetectionSeparatesInputsFromOutputs() {
        // Devices are only offered for a scope where they actually carry channels. If this were
        // wrong, microphones would appear in the output list.
        let devices = AudioSystem.devices()
        let outputs = AudioDeviceList.selectable(from: devices, kind: .output)
        let inputs = AudioDeviceList.selectable(from: devices, kind: .input)
        XCTAssertTrue(outputs.allSatisfy(\.hasOutput))
        XCTAssertTrue(inputs.allSatisfy(\.hasInput))
    }

    func testReadingTheInputDevicesVolumeOrMuteWorksOrIsHonestlyUnavailable() throws {
        // Not every device supports either property — that's exactly why the mute feature needs a
        // fallback chain. This asserts we can *ask* without crashing, not that it succeeds.
        guard let input = AudioSystem.defaultDevice(.input) else {
            throw XCTSkip("no input device on this machine")
        }
        let mute = AudioSystem.mute(input, scope: kAudioObjectPropertyScopeInput)
        let volume = AudioSystem.volume(input, scope: kAudioObjectPropertyScopeInput)
        XCTAssertTrue(mute != nil || volume != nil,
                      "an input device that supports neither mute nor volume can't be muted at all")
    }
}
