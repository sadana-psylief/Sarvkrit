import XCTest
@testable import Sarvkrit

/// The manifest round-tripping through JSON.
///
/// **The decoder is hand-written and the encoder is not, so they drift.** Adding a property gets it
/// written to disk for free and silently dropped on the way back — which is exactly what happened
/// to `cameraStartOffset`: the recorder measured the camera as starting 2.546 s after the screen,
/// wrote that number into `manifest.json`, and the editor then read it back as zero and put the
/// camera two and a half seconds ahead of the action.
///
/// `EventLog` had the same shape of bug for the same reason. One round-trip test per field is the
/// cheap way to stop it happening a third time.
final class RecordingManifestCodingTests: XCTestCase {

    private func roundTrip(_ manifest: RecordingManifest) throws -> RecordingManifest {
        let data = try JSONEncoder().encode(manifest)
        return try JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    func testEveryFieldSurvivesTheRoundTrip() throws {
        var manifest = RecordingManifest(source: .window, pixelSize: CGSize(width: 640, height: 480),
                                         pointPixelScale: 2, fps: 60)
        manifest.state = .complete
        manifest.duration = 29.175
        manifest.hasCamera = true
        manifest.hasMicrophone = true
        manifest.hasSystemAudio = true
        manifest.cameraStartOffset = 2.546
        manifest.droppedFrames = 7
        manifest.accessibilityCursorScale = 1.5
        manifest.displayID = 3

        let decoded = try roundTrip(manifest)

        XCTAssertEqual(decoded.state, .complete)
        XCTAssertEqual(decoded.source, .window)
        XCTAssertEqual(decoded.duration, 29.175, accuracy: 1e-9)
        XCTAssertTrue(decoded.hasCamera)
        XCTAssertTrue(decoded.hasMicrophone)
        XCTAssertTrue(decoded.hasSystemAudio)
        XCTAssertEqual(decoded.cameraStartOffset, 2.546, accuracy: 1e-9,
                       "the camera offset was dropped, so the camera plays out of step")
        XCTAssertEqual(decoded.droppedFrames, 7)
        XCTAssertEqual(decoded.accessibilityCursorScale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.displayID, 3)
    }

    /// A bundle recorded before the offset existed has no such key, and must read as zero rather
    /// than throwing — the manifest is the one file that has to stay readable.
    func testAnOlderManifestWithNoOffsetStillReads() throws {
        let json = """
        {"formatVersion":1,"state":"complete","source":"display",
         "pixelSize":{"width":100,"height":100},"pointPixelScale":2,"fps":60,
         "duration":5,"hasCamera":true}
        """
        let decoded = try JSONDecoder().decode(RecordingManifest.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.cameraStartOffset, 0)
        XCTAssertTrue(decoded.hasCamera)
    }
}
