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

    // MARK: - Order

    /// **Reordering is a move on an array, and that is not a coincidence.**
    ///
    /// `sourceTime(forOutput:)` walks the clips in array order, and every other track — zooms,
    /// masks, camera layouts, captions — is stored in *source* time and resolved through that
    /// mapping. So a clip carries its material with it, and whatever was attached to that material
    /// arrives with it. There was simply no method to do it: split, delete, trim and setSpeed, and
    /// nothing that changed order.
    func testMovingAClipChangesTheOrder() {
        let a = Clip(sourceStart: 0, sourceEnd: 2)
        let b = Clip(sourceStart: 10, sourceEnd: 13)
        let timeline = Timeline(clips: [a, b]).move(from: 0, to: 1)

        XCTAssertEqual(timeline.clips.map(\.id), [b.id, a.id])
    }

    func testMovingAClipKeepsTheTotalDuration() {
        let timeline = Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 2),
                                        Clip(sourceStart: 10, sourceEnd: 13)])
        XCTAssertEqual(timeline.move(from: 1, to: 0).duration, timeline.duration, accuracy: 1e-9)
    }

    /// The material moves with the clip: after the swap, the second half of the finished video
    /// shows what used to be the first.
    func testAMovedClipTakesItsMaterialWithIt() throws {
        let timeline = Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 2),
                                        Clip(sourceStart: 10, sourceEnd: 13)]).move(from: 0, to: 1)

        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(forOutput: 0.5)).sourceTime, 10.5,
                       accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(forOutput: 3.5)).sourceTime, 0.5,
                       accuracy: 1e-9)
    }

    /// A move that changes nothing is refused, so it costs no undo step.
    func testAMoveToTheSamePlaceIsRefused() {
        let timeline = Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 2),
                                        Clip(sourceStart: 10, sourceEnd: 13)])
        XCTAssertEqual(timeline.move(from: 0, to: 0), timeline)
    }

    func testAMoveOutOfBoundsIsRefused() {
        let timeline = Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 2)])
        XCTAssertEqual(timeline.move(from: 0, to: 7), timeline)
        XCTAssertEqual(timeline.move(from: 4, to: 0), timeline)
    }

    // MARK: - Duplicate

    func testDuplicatingAClipAddsItAfterTheOriginal() {
        let a = Clip(sourceStart: 0, sourceEnd: 2)
        let b = Clip(sourceStart: 10, sourceEnd: 13)
        let timeline = Timeline(clips: [a, b]).duplicate(id: a.id)

        XCTAssertEqual(timeline.clips.count, 3)
        XCTAssertEqual(timeline.clips[0].id, a.id)
        XCTAssertEqual(timeline.clips[2].id, b.id)
    }

    /// A new identity, or selection and every per-clip edit would address both at once.
    func testADuplicateGetsItsOwnIdentity() {
        let a = Clip(sourceStart: 0, sourceEnd: 2)
        let timeline = Timeline(clips: [a]).duplicate(id: a.id)
        XCTAssertNotEqual(timeline.clips[0].id, timeline.clips[1].id)
    }

    func testADuplicateShowsTheSameMaterialTwice() throws {
        let a = Clip(sourceStart: 4, sourceEnd: 6)
        let timeline = Timeline(clips: [a]).duplicate(id: a.id)

        XCTAssertEqual(timeline.duration, 4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(forOutput: 0.5)).sourceTime, 4.5,
                       accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(forOutput: 2.5)).sourceTime, 4.5,
                       accuracy: 1e-9)
    }

    // MARK: - Rolling a cut

    /// Dragging the seam between two clips moves material from one to the other without changing
    /// where the cut sits in the finished video — the thing a cut is usually adjusted *for*.
    func testRollingACutTradesMaterialBetweenNeighbours() {
        let a = Clip(sourceStart: 0, sourceEnd: 5)
        let b = Clip(sourceStart: 5, sourceEnd: 10)
        let rolled = Timeline(clips: [a, b]).roll(after: a.id, by: 1)

        XCTAssertEqual(rolled.clips[0].sourceEnd, 6, accuracy: 1e-9)
        XCTAssertEqual(rolled.clips[1].sourceStart, 6, accuracy: 1e-9)
        XCTAssertEqual(rolled.duration, 10, accuracy: 1e-9)
    }

    /// A roll that would leave either side too small to grab is refused rather than performed.
    func testARollThatWouldLeaveASliverIsRefused() {
        let a = Clip(sourceStart: 0, sourceEnd: 5)
        let b = Clip(sourceStart: 5, sourceEnd: 10)
        let timeline = Timeline(clips: [a, b])
        XCTAssertEqual(timeline.roll(after: a.id, by: 5), timeline)
        XCTAssertEqual(timeline.roll(after: a.id, by: -5), timeline)
    }

    // MARK: - Freeze frame

    /// **A held frame is a clip that keeps showing its last moment.** One field rather than a new
    /// type, so it composes with speed and trimming instead of sitting beside them.
    func testAHoldLengthensTheClipWithoutConsumingMoreSource() {
        var clip = Clip(sourceStart: 0, sourceEnd: 4)
        clip.hold = 3
        let timeline = Timeline(clips: [clip])

        XCTAssertEqual(timeline.duration, 7, accuracy: 1e-9)
    }

    func testDuringTheHoldTheSourceTimeStopsAtTheEnd() throws {
        var clip = Clip(sourceStart: 0, sourceEnd: 4)
        clip.hold = 3
        let timeline = Timeline(clips: [clip])

        let moving = try XCTUnwrap(timeline.sourceTime(forOutput: 2)).sourceTime
        let held = try XCTUnwrap(timeline.sourceTime(forOutput: 5.5)).sourceTime
        let later = try XCTUnwrap(timeline.sourceTime(forOutput: 6.5)).sourceTime

        XCTAssertEqual(moving, 2, accuracy: 1e-9)
        XCTAssertEqual(held, 4, accuracy: 0.001, "the hold should show the clip's last frame")
        XCTAssertEqual(later, held, accuracy: 1e-9, "the held frame must not drift")
    }

    /// It composes with speed: the moving part is shortened, the hold is not.
    func testAHoldIsNotAffectedBySpeed() {
        var clip = Clip(sourceStart: 0, sourceEnd: 4)
        clip.speed = 2
        clip.hold = 3
        XCTAssertEqual(Timeline(clips: [clip]).duration, 5, accuracy: 1e-9)
    }

    /// And the clip after a hold still starts where it should.
    func testAClipAfterAHoldStartsAfterIt() throws {
        var first = Clip(sourceStart: 0, sourceEnd: 2)
        first.hold = 2
        let second = Clip(sourceStart: 20, sourceEnd: 22)
        let timeline = Timeline(clips: [first, second])

        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(forOutput: 4.5)).sourceTime, 20.5,
                       accuracy: 1e-9)
    }

    // MARK: - Older projects

    /// **A project saved before a field existed must still open.**
    ///
    /// `Clip` uses synthesized `Codable`, and a synthesized decoder throws on a missing key even
    /// when the property has a default — a default is not the same as optional. So every field
    /// added here is a chance to make every saved project unreadable, and
    /// `StudioDocumentModel` treats an unreadable project as "no project", which would silently
    /// discard somebody's edits.
    func testAClipSavedBeforeHoldExistedStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceStart":0,"sourceEnd":5,"speed":1,
         "volume":1,"systemAudioVolume":1,"isMuted":false,"hidesCursor":false,
         "disablesCursorSmoothing":false}
        """
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertEqual(clip.hold, 0)
        XCTAssertEqual(clip.sourceEnd, 5, accuracy: 1e-9)
    }
}
