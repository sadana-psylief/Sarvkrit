import XCTest
@testable import Sarvkrit

/// The mute fallback chain. Worth testing carefully because the failure mode is the worst one this
/// feature has: appearing to mute while leaving the microphone live.
final class MicMuteStateTests: XCTestCase {

    private func capability(
        mute: Bool = true, volume: Bool = true, current: Float? = 0.7
    ) -> MicMuteState.Capability {
        MicMuteState.Capability(
            muteIsSettable: mute, volumeIsSettable: volume, currentVolume: current
        )
    }

    // MARK: - Preferring the mute property

    func testTheMutePropertyIsUsedWhenAvailable() {
        XCTAssertEqual(
            MicMuteState.action(muting: true, capability: capability(), restoreVolume: nil),
            .setMute(true)
        )
        XCTAssertEqual(
            MicMuteState.action(muting: false, capability: capability(), restoreVolume: nil),
            .setMute(false)
        )
    }

    func testTheMutePropertyDoesNotDisturbTheVolume() {
        // Nothing to remember, because nothing was changed.
        XCTAssertNil(MicMuteState.volumeToRemember(capability: capability(mute: true)))
    }

    // MARK: - Falling back to volume

    func testVolumeIsZeroedWhenMuteIsNotSettable() {
        // The Bluetooth case, and plenty of USB interfaces: setting mute silently does nothing, so
        // a feature that only knew that one mechanism would leave the mic live.
        XCTAssertEqual(
            MicMuteState.action(
                muting: true, capability: capability(mute: false), restoreVolume: nil
            ),
            .setVolume(0)
        )
    }

    func testUnmutingRestoresTheRememberedVolume() {
        XCTAssertEqual(
            MicMuteState.action(
                muting: false, capability: capability(mute: false), restoreVolume: 0.42
            ),
            .setVolume(0.42)
        )
    }

    func testUnmutingWithNothingRememberedGoesToFull() {
        // Not ideal, but the only sensible answer — and it can only happen if the remembered value
        // was lost, e.g. the app was relaunched while muted.
        XCTAssertEqual(
            MicMuteState.action(
                muting: false, capability: capability(mute: false), restoreVolume: nil
            ),
            .setVolume(1)
        )
    }

    func testTheVolumeIsRememberedBeforeZeroingIt() {
        XCTAssertEqual(MicMuteState.volumeToRemember(capability: capability(mute: false, current: 0.35)),
                       0.35)
    }

    func testAVolumeAlreadyAtZeroIsNotRemembered() {
        // Remembering zero would mean unmuting to silence, which looks exactly like the feature
        // failing to work.
        XCTAssertNil(MicMuteState.volumeToRemember(capability: capability(mute: false, current: 0)))
    }

    func testAnUnreadableVolumeIsNotRemembered() {
        XCTAssertNil(MicMuteState.volumeToRemember(capability: capability(mute: false, current: nil)))
    }

    // MARK: - Devices we simply cannot mute

    func testADeviceWithNeitherMechanismIsUnsupported() {
        // Said plainly rather than pretending: the pane can then tell the user, instead of a switch
        // that flips and does nothing.
        XCTAssertEqual(
            MicMuteState.action(
                muting: true,
                capability: capability(mute: false, volume: false, current: nil),
                restoreVolume: nil
            ),
            .unsupported
        )
    }

    func testUnsupportedAppliesToUnmutingToo() {
        XCTAssertEqual(
            MicMuteState.action(
                muting: false,
                capability: capability(mute: false, volume: false, current: nil),
                restoreVolume: 0.5
            ),
            .unsupported
        )
    }

    // MARK: - Reading the current state

    func testTheMutePropertyIsBelievedWhenPresent() {
        XCTAssertTrue(MicMuteState.isMuted(muteProperty: true, volume: 0.8))
        XCTAssertFalse(MicMuteState.isMuted(muteProperty: false, volume: 0))
    }

    func testWithoutAMutePropertyZeroVolumeMeansMuted() {
        XCTAssertTrue(MicMuteState.isMuted(muteProperty: nil, volume: 0))
        XCTAssertFalse(MicMuteState.isMuted(muteProperty: nil, volume: 0.5))
    }

    func testAVeryQuietButNonZeroVolumeIsNotMuted() {
        // Floating point: a device reporting 0.00005 is effectively silent and should read as muted,
        // but 0.01 is a real if quiet level.
        XCTAssertTrue(MicMuteState.isMuted(muteProperty: nil, volume: 0.00005))
        XCTAssertFalse(MicMuteState.isMuted(muteProperty: nil, volume: 0.01))
    }

    func testNoSignalAtAllReadsAsNotMuted() {
        // Safer direction to fail: claiming muted when we don't know would be the dangerous lie.
        XCTAssertFalse(MicMuteState.isMuted(muteProperty: nil, volume: nil))
    }
}
