import XCTest
@testable import Sarvkrit

/// Does the camera check actually reach the hardware, and does it stay within "asking about a
/// device" rather than "opening one"?
///
/// Touches real hardware, like `AudioSystemSmokeTests`, and for the same reason: a layer that
/// compiles and returns plausible-looking nothing is the failure mode this project has hit before.
final class CameraMonitorSmokeTests: XCTestCase {

    func testTheMachineReportsAtLeastOneCamera() {
        // Every Mac with a built-in camera should report one. If this returns zero on a machine
        // that plainly has a camera, the enumeration is wrong — which would make the whole feature
        // silently report "never on".
        XCTAssertGreaterThan(CameraMonitor.cameraCount(), 0,
                             "no cameras found — enumeration is broken, or this Mac has none")
    }

    func testAskingWhetherTheCameraIsOnDoesNotCrashOrHang() {
        // The answer depends on what's running, so there is nothing to assert about the value —
        // only that asking works at all.
        _ = CameraMonitor.isAnyCameraOn()
    }

    func testRepeatedPollingIsStable() {
        // This runs twice a second for as long as the feature is on; it must not degrade or leak
        // its way to a different answer.
        let first = CameraMonitor.isAnyCameraOn()
        for _ in 0..<50 {
            XCTAssertEqual(CameraMonitor.isAnyCameraOn(), first,
                           "the answer changed mid-test, or polling is unstable")
        }
    }

    func testTheMicrophoneInUseCheckAlsoWorks() {
        // Same question, asked of audio.
        _ = MicrophoneMuter.isInUse()
    }
}
