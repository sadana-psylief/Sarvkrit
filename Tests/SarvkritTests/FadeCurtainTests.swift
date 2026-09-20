import XCTest
@testable import Sarvkrit

/// The black wash: a fade up from black, a fade down to it, and a dip at a cut.
///
/// **One piece of arithmetic for three features**, because they are the same wash at different
/// times. Dip-to-black rather than crossfade is a deliberate limit: a crossfade needs the outgoing
/// *and* incoming frames at once, so a second decoder in the player and buffering in the exporter,
/// where a dip needs the one frame it already has.
final class FadeCurtainTests: XCTestCase {

    func testWithNoFadesTheFrameIsNeverWashed() {
        XCTAssertEqual(FadeCurtain.alpha(atOutput: 3, duration: 10, fadeIn: 0, fadeOut: 0), 0)
    }

    func testTheFirstFrameIsBlackAndItClearsByTheEndOfTheFade() {
        XCTAssertEqual(FadeCurtain.alpha(atOutput: 0, duration: 10, fadeIn: 1, fadeOut: 0), 1,
                       accuracy: 1e-9)
        XCTAssertEqual(FadeCurtain.alpha(atOutput: 0.5, duration: 10, fadeIn: 1, fadeOut: 0), 0.5,
                       accuracy: 1e-9)
        XCTAssertEqual(FadeCurtain.alpha(atOutput: 1, duration: 10, fadeIn: 1, fadeOut: 0), 0,
                       accuracy: 1e-9)
    }

    func testTheLastFrameFadesDownToBlack() {
        XCTAssertEqual(FadeCurtain.alpha(atOutput: 10, duration: 10, fadeIn: 0, fadeOut: 2), 1,
                       accuracy: 1e-9)
        XCTAssertEqual(FadeCurtain.alpha(atOutput: 9, duration: 10, fadeIn: 0, fadeOut: 2), 0.5,
                       accuracy: 1e-9)
        XCTAssertEqual(FadeCurtain.alpha(atOutput: 7, duration: 10, fadeIn: 0, fadeOut: 2), 0,
                       accuracy: 1e-9)
    }

    /// A dip is fully black at the cut and clear at either end of its length.
    func testADipIsBlackAtTheCut() {
        let dips = [FadeCurtain.Dip(at: 5, length: 1)]
        XCTAssertEqual(FadeCurtain.alpha(atOutput: 5, duration: 10, fadeIn: 0, fadeOut: 0,
                                         dips: dips), 1, accuracy: 1e-9)
        XCTAssertEqual(FadeCurtain.alpha(atOutput: 4.75, duration: 10, fadeIn: 0, fadeOut: 0,
                                         dips: dips), 0.5, accuracy: 1e-9)
        XCTAssertEqual(FadeCurtain.alpha(atOutput: 4.4, duration: 10, fadeIn: 0, fadeOut: 0,
                                         dips: dips), 0, accuracy: 1e-9)
    }

    /// Overlapping washes take the darkest rather than adding up, or a dip inside a fade would
    /// go past black and clip.
    func testOverlappingWashesTakeTheDarkest() {
        let alpha = FadeCurtain.alpha(atOutput: 0.5, duration: 10, fadeIn: 2, fadeOut: 0,
                                      dips: [FadeCurtain.Dip(at: 0.5, length: 1)])
        XCTAssertEqual(alpha, 1, accuracy: 1e-9)
    }

    // MARK: - Where the dips fall

    func testADipBelongsToTheClipThatStartsAtTheCut() {
        var second = Clip(sourceStart: 10, sourceEnd: 14)
        second.dipToBlack = 0.5
        let timeline = Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 6), second])

        XCTAssertEqual(FadeCurtain.dips(in: timeline), [FadeCurtain.Dip(at: 6, length: 0.5)])
    }

    /// The first clip has no cut before it — a fade in is the setting for that.
    func testTheFirstClipCannotDip() {
        var first = Clip(sourceStart: 0, sourceEnd: 6)
        first.dipToBlack = 1
        XCTAssertTrue(FadeCurtain.dips(in: Timeline(clips: [first])).isEmpty)
    }

    /// Dips are placed in output time, so a speed change moves them with the picture.
    func testDipsFollowSpeedChanges() {
        var first = Clip(sourceStart: 0, sourceEnd: 8)
        first.speed = 2
        var second = Clip(sourceStart: 10, sourceEnd: 14)
        second.dipToBlack = 0.4

        XCTAssertEqual(FadeCurtain.dips(in: Timeline(clips: [first, second])),
                       [FadeCurtain.Dip(at: 4, length: 0.4)])
    }
}
