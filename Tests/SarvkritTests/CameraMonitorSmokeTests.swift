import XCTest
@testable import Sarvkrit

/// Does the camera check actually reach the hardware, and does it stay within "asking about a
/// device" rather than "opening one"?
///
/// Touches real hardware, like `AudioSystemSmokeTests`, and for the same reason: a layer that
/// compiles and returns plausible-looking nothing is the failure mode this project has hit before.
final class CameraMonitorSmokeTests: XCTestCase {

    func testTheMachineReportsAtLeastOneCamera() throws {
        // Every Mac with a camera should report one. If this returns zero on a machine that
        // plainly has a camera, the enumeration is wrong — which would make the whole feature
        // silently report "never on".
        //
        // "Plainly has a camera" needs an answer from somewhere other than the code under test.
        // Asserting the count outright cannot tell *no camera* from *enumeration is broken*, and
        // those want opposite outcomes: the first is a machine this test has nothing to say about,
        // the second is the bug it exists to catch. Conflating them is what made this fail on CI
        // runners, which have no camera, and kept the whole suite out of the gating checks.
        try XCTSkipUnless(Self.systemReportsACamera(),
                          "this machine has no camera, so there is nothing to check enumeration against")

        XCTAssertGreaterThan(CameraMonitor.cameraCount(), 0,
                             "the system reports a camera but CoreMediaIO enumeration found none")
    }

    /// Whether the machine has a camera, according to something that is **not** CoreMediaIO.
    ///
    /// `system_profiler` is the independent source: a different subsystem, no capture session, and
    /// — unlike enumerating through AVFoundation — nothing that could put a permission prompt in
    /// front of a test run. It costs about a third of a second, which is worth paying once to make
    /// the assertion above mean something.
    ///
    /// Deliberately not compared for *equality* with `cameraCount()`. The two disagree legitimately
    /// — Continuity Camera shows up here whether or not CoreMediaIO is currently listing it — so
    /// the only sound assertion is directional: if this says there is a camera, enumeration must
    /// find at least one.
    private static func systemReportsACamera() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPCameraDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        // Read before waiting: a full pipe buffer with nobody draining it deadlocks both sides.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cameras = json["SPCameraDataType"] as? [Any]
        else { return false }
        return !cameras.isEmpty
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
