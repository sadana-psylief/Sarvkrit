import XCTest
@testable import Sarvkrit

/// The wording shown when a recording will not start.
///
/// Every one of these used to be the same sentence — "Couldn't start recording" — which is why a
/// window that had closed, a disk with no room, and a screen grant that had gone stale were all
/// reported as "it does nothing".
final class RecordingFailureMessageTests: XCTestCase {

    func testEachCauseGetsItsOwnSentence() {
        let causes: [RecordingError] = [
            .noDisplays, .displayGone, .windowGone, .cannotWrite,
            .alreadyRecording, .outOfSpace(freeBytes: 1), .cancelled,
        ]
        let sentences = causes.map { RecordingFailureMessage.describe($0).text }

        XCTAssertEqual(Set(sentences).count, causes.count,
                       "two different failures produced the same message")
        XCTAssertFalse(sentences.contains { $0.isEmpty })
    }

    func testFreeSpaceIsNamedInGigabytes() {
        let (text, _) = RecordingFailureMessage.describe(RecordingError.outOfSpace(freeBytes: 2_400_000_000))
        XCTAssertEqual(text, "Only 2.4 GB free")
    }

    /// An error from AVFoundation or ScreenCaptureKit that we have no case for still says
    /// something specific rather than falling back to the generic line.
    func testAnUnknownErrorKeepsItsOwnDescription() {
        let underlying = NSError(domain: "SCStream", code: -3801,
                                 userInfo: [NSLocalizedDescriptionKey: "The stream failed to start"])
        XCTAssertEqual(RecordingFailureMessage.describe(underlying).text, "The stream failed to start")
    }
}
