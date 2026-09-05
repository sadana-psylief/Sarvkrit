import XCTest
@testable import Sarvkrit

/// The mapping between the edit and the recording it was made from.
///
/// **Every desynchronisation bug in the studio lives in one function.** The cursor, the zooms, the
/// captions and the keystrokes are all stored in *source* time and looked up through
/// `sourceTime(forOutput:)`; the video frame is fetched through the same call. If that mapping is
/// wrong by a frame, everything but the video moves together and the recording looks like it was
/// dubbed. So the arithmetic is a pure struct and this suite is exhaustive about it.
final class TimelineTests: XCTestCase {

    private func clip(_ start: TimeInterval, _ end: TimeInterval,
                      speed: Double = 1) -> Clip {
        Clip(sourceStart: start, sourceEnd: end, speed: speed)
    }

    // MARK: - Duration

    func testAnUntouchedTimelineIsAsLongAsItsClip() {
        let timeline = Timeline(clips: [clip(0, 10)])
        XCTAssertEqual(timeline.duration, 10, accuracy: 0.0001)
    }

    func testDurationIsTheSumOfTheClips() {
        let timeline = Timeline(clips: [clip(0, 4), clip(6, 10)])
        XCTAssertEqual(timeline.duration, 8, accuracy: 0.0001)
    }

    /// Double speed halves the time a clip occupies in the finished video.
    func testSpeedShortensAClipsContributionToTheDuration() {
        let timeline = Timeline(clips: [clip(0, 10, speed: 2)])
        XCTAssertEqual(timeline.duration, 5, accuracy: 0.0001)
    }

    func testHalfSpeedLengthensIt() {
        let timeline = Timeline(clips: [clip(0, 10, speed: 0.5)])
        XCTAssertEqual(timeline.duration, 20, accuracy: 0.0001)
    }

    func testAnEmptyTimelineHasNoDuration() {
        XCTAssertEqual(Timeline(clips: []).duration, 0)
    }

    // MARK: - Output to source

    func testOutputTimeMapsStraightThroughAtNormalSpeed() {
        let timeline = Timeline(clips: [clip(0, 10)])
        let found = timeline.sourceTime(forOutput: 3)
        XCTAssertEqual(found?.sourceTime ?? -1, 3, accuracy: 0.0001)
    }

    /// The whole point of `sourceStart`: a trimmed clip's output zero is not the recording's zero.
    func testATrimmedClipOffsetsTheLookup() {
        let timeline = Timeline(clips: [clip(5, 15)])
        let found = timeline.sourceTime(forOutput: 2)
        XCTAssertEqual(found?.sourceTime ?? -1, 7, accuracy: 0.0001)
    }

    func testASpedUpClipConsumesSourceFaster() {
        let timeline = Timeline(clips: [clip(0, 10, speed: 2)])
        let found = timeline.sourceTime(forOutput: 2)
        XCTAssertEqual(found?.sourceTime ?? -1, 4, accuracy: 0.0001)
    }

    /// A cut in the middle: output 5 lands in the second clip, which starts at source 20.
    func testTheLookupCrossesIntoTheSecondClip() {
        let timeline = Timeline(clips: [clip(0, 4), clip(20, 30)])
        let found = timeline.sourceTime(forOutput: 5)
        XCTAssertEqual(found?.sourceTime ?? -1, 21, accuracy: 0.0001)
        XCTAssertEqual(found?.clip.sourceStart, 20)
    }

    func testTheLookupIsNilPastTheEnd() {
        let timeline = Timeline(clips: [clip(0, 4)])
        XCTAssertNil(timeline.sourceTime(forOutput: 9))
    }

    func testTheLookupIsNilBeforeTheStart() {
        let timeline = Timeline(clips: [clip(0, 4)])
        XCTAssertNil(timeline.sourceTime(forOutput: -1))
    }

    /// The boundary belongs to the clip that starts there, not the one that ended.
    func testAnExactBoundaryLandsInTheFollowingClip() {
        let timeline = Timeline(clips: [clip(0, 4), clip(20, 30)])
        let found = timeline.sourceTime(forOutput: 4)
        XCTAssertEqual(found?.clip.sourceStart, 20)
        XCTAssertEqual(found?.sourceTime ?? -1, 20, accuracy: 0.0001)
    }

    /// Asked for exactly the end, there is no frame to show — the video is over.
    func testTheLookupIsNilAtExactlyTheDuration() {
        let timeline = Timeline(clips: [clip(0, 4)])
        XCTAssertNil(timeline.sourceTime(forOutput: 4))
    }

    // MARK: - Split

    func testSplittingMakesTwoClipsOutOfOne() {
        let timeline = Timeline(clips: [clip(0, 10)]).split(at: 4)
        XCTAssertEqual(timeline.clips.count, 2)
        XCTAssertEqual(timeline.clips[0].sourceEnd, 4, accuracy: 0.0001)
        XCTAssertEqual(timeline.clips[1].sourceStart, 4, accuracy: 0.0001)
    }

    func testSplittingPreservesTheTotalDuration() {
        let timeline = Timeline(clips: [clip(0, 10)]).split(at: 4)
        XCTAssertEqual(timeline.duration, 10, accuracy: 0.0001)
    }

    /// The split point is given in output time, so a sped-up clip splits at the source time the
    /// user is actually looking at — not at the same number.
    func testSplittingASpedUpClipCutsAtTheRightSourceTime() {
        let timeline = Timeline(clips: [clip(0, 10, speed: 2)]).split(at: 2)
        XCTAssertEqual(timeline.clips[0].sourceEnd, 4, accuracy: 0.0001)
    }

    func testSplittingCarriesTheSpeedToBothHalves() {
        let timeline = Timeline(clips: [clip(0, 10, speed: 2)]).split(at: 2)
        XCTAssertEqual(timeline.clips[0].speed, 2)
        XCTAssertEqual(timeline.clips[1].speed, 2)
    }

    func testTheTwoHalvesGetDifferentIdentities() {
        let timeline = Timeline(clips: [clip(0, 10)]).split(at: 4)
        XCTAssertNotEqual(timeline.clips[0].id, timeline.clips[1].id)
    }

    /// A split that would leave a sliver nobody can grab is refused rather than performed.
    func testSplittingTooCloseToTheStartIsRefused() {
        let original = Timeline(clips: [clip(0, 10)])
        XCTAssertEqual(original.split(at: 0.02).clips.count, 1)
    }

    func testSplittingTooCloseToTheEndIsRefused() {
        let original = Timeline(clips: [clip(0, 10)])
        XCTAssertEqual(original.split(at: 9.98).clips.count, 1)
    }

    func testSplittingPastTheEndDoesNothing() {
        XCTAssertEqual(Timeline(clips: [clip(0, 10)]).split(at: 40).clips.count, 1)
    }

    // MARK: - Delete

    func testDeletingRemovesTheClipAndClosesTheGap() {
        let first = clip(0, 4), second = clip(20, 30)
        let timeline = Timeline(clips: [first, second]).delete(id: first.id)
        XCTAssertEqual(timeline.clips.count, 1)
        XCTAssertEqual(timeline.duration, 10, accuracy: 0.0001)
        XCTAssertEqual(timeline.sourceTime(forOutput: 0)?.sourceTime ?? -1, 20, accuracy: 0.0001)
    }

    /// Deleting the last clip would leave a timeline that cannot be edited back into existence.
    func testTheLastClipCannotBeDeleted() {
        let only = clip(0, 10)
        let timeline = Timeline(clips: [only]).delete(id: only.id)
        XCTAssertEqual(timeline.clips.count, 1)
    }

    func testDeletingAnUnknownIdChangesNothing() {
        let timeline = Timeline(clips: [clip(0, 4), clip(6, 8)])
        XCTAssertEqual(timeline.delete(id: UUID()).clips.count, 2)
    }

    // MARK: - Trim

    func testTrimmingTheStartMovesSourceStart() {
        let only = clip(0, 10)
        let timeline = Timeline(clips: [only]).trim(id: only.id, start: 3, end: nil)
        XCTAssertEqual(timeline.clips[0].sourceStart, 3, accuracy: 0.0001)
        XCTAssertEqual(timeline.duration, 7, accuracy: 0.0001)
    }

    func testTrimmingTheEndMovesSourceEnd() {
        let only = clip(0, 10)
        let timeline = Timeline(clips: [only]).trim(id: only.id, start: nil, end: 6)
        XCTAssertEqual(timeline.clips[0].sourceEnd, 6, accuracy: 0.0001)
    }

    /// Trim is a view onto the recording, so it is reversible — that is what lets the trim badge
    /// honestly say how much is hidden, and what makes clicking it put the material back.
    func testTrimmingBackOutRestoresTheMaterial() {
        let only = clip(0, 10)
        let trimmed = Timeline(clips: [only]).trim(id: only.id, start: 3, end: nil)
        let restored = trimmed.trim(id: only.id, start: 0, end: nil)
        XCTAssertEqual(restored.duration, 10, accuracy: 0.0001)
    }

    func testTrimmingPastTheOtherEdgeIsRefused() {
        let only = clip(0, 10)
        let timeline = Timeline(clips: [only]).trim(id: only.id, start: 9.99, end: nil)
        XCTAssertEqual(timeline.clips[0].sourceStart, 0, accuracy: 0.0001)
    }

    // MARK: - Speed

    func testSettingSpeedChangesTheDuration() {
        let only = clip(0, 10)
        let timeline = Timeline(clips: [only]).setSpeed(id: only.id, 4)
        XCTAssertEqual(timeline.duration, 2.5, accuracy: 0.0001)
    }

    func testSpeedIsClampedToTheSupportedRange() {
        let only = clip(0, 10)
        XCTAssertEqual(Timeline(clips: [only]).setSpeed(id: only.id, 99).clips[0].speed,
                       Clip.speedRange.upperBound)
        XCTAssertEqual(Timeline(clips: [only]).setSpeed(id: only.id, 0).clips[0].speed,
                       Clip.speedRange.lowerBound)
    }

    // MARK: - Source to output

    /// The inverse mapping, which is what puts a zoom segment stored in source time onto the
    /// timeline in the right place.
    func testSourceTimeMapsBackToOutputTime() {
        let timeline = Timeline(clips: [clip(0, 4), clip(20, 30)])
        XCTAssertEqual(timeline.outputTime(forSource: 22) ?? -1, 6, accuracy: 0.0001)
    }

    /// Source that was cut out has no place in the output at all, and saying so is what lets the
    /// renderer skip a zoom whose moment was deleted.
    func testSourceInsideACutHasNoOutputTime() {
        let timeline = Timeline(clips: [clip(0, 4), clip(20, 30)])
        XCTAssertNil(timeline.outputTime(forSource: 10))
    }

    func testTheTwoMappingsAreInverses() {
        let timeline = Timeline(clips: [clip(2, 6, speed: 2), clip(20, 30, speed: 0.5)])
        for output in stride(from: 0.0, to: timeline.duration - 0.01, by: 0.37) {
            guard let source = timeline.sourceTime(forOutput: output) else {
                return XCTFail("no source for output \(output)")
            }
            guard let back = timeline.outputTime(forSource: source.sourceTime) else {
                return XCTFail("no output for source \(source.sourceTime)")
            }
            XCTAssertEqual(back, output, accuracy: 0.001)
        }
    }
}
