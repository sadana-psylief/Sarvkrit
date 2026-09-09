import AppKit
import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The small decisions the editor's chrome rests on: click effects, export presets, key routing
/// and the recording sources. All pure, all exhaustively enumerable, none of them needing a window.
final class StudioChromeLogicTests: XCTestCase {

    // MARK: - Click effects

    func testNoEffectNeverDrawsAnything() {
        XCTAssertNil(ClickEffect.state(.none, secondsSinceClick: 0))
        XCTAssertNil(ClickEffect.state(.none, secondsSinceClick: 0.1))
    }

    func testAnEffectDrawsNothingBeforeTheClick() {
        XCTAssertNil(ClickEffect.state(.ripple, secondsSinceClick: -0.01))
    }

    func testAnEffectIsOverAfterItsDuration() {
        XCTAssertNil(ClickEffect.state(.ripple, secondsSinceClick: ClickEffect.duration + 0.001))
    }

    func testARippleExpands() {
        var previous = -1.0
        for step in 0...20 {
            let t = ClickEffect.duration * Double(step) / 20
            let radius = ClickEffect.state(.ripple, secondsSinceClick: t)?.ringRadius ?? -1
            XCTAssertGreaterThanOrEqual(radius, previous)
            previous = radius
        }
    }

    /// A ripple that is still solid when it stops reads as a rendering glitch rather than an
    /// effect ending.
    func testARippleFadesOutCompletely() {
        let end = ClickEffect.state(.ripple, secondsSinceClick: ClickEffect.duration * 0.999)
        XCTAssertLessThan(end?.ringAlpha ?? 1, 0.05)
    }

    func testARippleStartsSolid() {
        XCTAssertGreaterThan(ClickEffect.state(.ripple, secondsSinceClick: 0)?.ringAlpha ?? 0, 0.5)
    }

    /// The subtle one: the pointer itself dips, which reads as "the mouse was pressed" rather than
    /// as "an effect played".
    func testShrinkPullsTheCursorInAndPutsItBack() {
        XCTAssertLessThan(ClickEffect.state(.shrink, secondsSinceClick: 0.02)?.cursorScale ?? 1, 1)
        let end = ClickEffect.state(.shrink, secondsSinceClick: ClickEffect.duration * 0.999)
        XCTAssertEqual(end?.cursorScale ?? 0, 1, accuracy: 0.05)
    }

    func testShrinkNeverMovesTheRing() {
        XCTAssertEqual(ClickEffect.state(.shrink, secondsSinceClick: 0.05)?.ringAlpha ?? 1, 0)
    }

    func testAHighlightFades() {
        let early = ClickEffect.state(.highlight, secondsSinceClick: 0.01)?.fillAlpha ?? 0
        let late = ClickEffect.state(.highlight, secondsSinceClick: 0.18)?.fillAlpha ?? 1
        XCTAssertGreaterThan(early, late)
    }

    func testEveryStyleKeepsItsAlphasInRange() {
        for style in ClickEffectStyle.allCases {
            for step in 0...30 {
                let t = ClickEffect.duration * Double(step) / 30
                guard let state = ClickEffect.state(style, secondsSinceClick: t) else { continue }
                XCTAssertTrue((0...1).contains(state.ringAlpha), "\(style.rawValue)")
                XCTAssertTrue((0...1).contains(state.fillAlpha), "\(style.rawValue)")
                XCTAssertGreaterThan(state.cursorScale, 0, "\(style.rawValue)")
            }
        }
    }

    // MARK: - Export presets

    func testEveryPresetHasItsOwnIdentity() {
        let ids = ExportPreset.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// The default has to play everywhere — a Slack preview, a PowerPoint slide, a PR comment.
    func testTheDefaultPresetIsPlayableEverywhere() {
        XCTAssertEqual(ExportPreset.web.codec, .h264)
        XCTAssertEqual(ExportPreset.web.height, 1080)
    }

    /// **This asserted `separatesAudioTracks`, a flag nothing implemented.** The exporter writes
    /// one AAC track whatever the preset says, so the test was pinning a promise the app did not
    /// keep — the worst kind of green. The flag is gone; what the editor preset actually offers is
    /// ProRes at full size, and that is what is asserted.
    func testTheEditorPresetIsProResAtFullSize() {
        XCTAssertEqual(ExportPreset.forEditing.codec, .proRes422)
        XCTAssertNil(ExportPreset.forEditing.height)
        XCTAssertEqual(ExportPreset.forEditing.fileType, .mov)
    }

    func testAPresetPreservesTheCanvasAspect() {
        let size = ExportPreset.web.outputSize(forCanvas: CGSize(width: 3000, height: 2000))
        XCTAssertEqual(size.width / size.height, 1.5, accuracy: 0.01)
    }

    /// **Odd dimensions cost quality for nothing.** H.264 and HEVC work in macroblocks, and an odd
    /// width forces the encoder to pad — so every size this hands back is even.
    func testEveryOutputSizeIsEven() {
        let canvases = [CGSize(width: 1001, height: 667), CGSize(width: 2557, height: 1439),
                        CGSize(width: 999, height: 999)]
        for preset in ExportPreset.all where preset.codec != .gif {
            for canvas in canvases {
                let size = preset.outputSize(forCanvas: canvas)
                XCTAssertEqual(Int(size.width) % 2, 0, "\(preset.id) \(canvas)")
                XCTAssertEqual(Int(size.height) % 2, 0, "\(preset.id) \(canvas)")
            }
        }
    }

    func testAPresetWithNoHeightKeepsTheCanvasSize() {
        let canvas = CGSize(width: 2560, height: 1440)
        XCTAssertEqual(ExportPreset.forEditing.outputSize(forCanvas: canvas), canvas)
    }

    /// Upscaling a 720p recording to 4K makes a bigger file and not a better video.
    func testAPresetNeverUpscales() {
        let size = ExportPreset.web.outputSize(forCanvas: CGSize(width: 640, height: 360))
        XCTAssertEqual(size.height, 360)
    }

    // MARK: - Key routing

    private func action(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [],
                        editing: Bool = false) -> StudioKeyRouting.Action? {
        StudioKeyRouting.action(forCharacters: characters, modifiers: modifiers,
                                isEditingText: editing)
    }

    func testSpacePlaysAndPauses() {
        XCTAssertEqual(action(" "), .playPause)
    }

    func testArrowsStepAFrame() {
        XCTAssertEqual(action("\u{F702}"), .stepFrames(-1))
        XCTAssertEqual(action("\u{F703}"), .stepFrames(1))
    }

    func testShiftedArrowsStepASecond() {
        XCTAssertEqual(action("\u{F703}", .shift), .stepSeconds(1))
    }

    /// J/K/L is the shuttle every editor has, and anyone who has used one reaches for it without
    /// thinking about it.
    func testTheShuttleKeysShuttle() {
        XCTAssertEqual(action("l"), .shuttle(1))
        XCTAssertEqual(action("j"), .shuttle(-1))
        XCTAssertEqual(action("k"), .shuttle(0))
    }

    /// Two different deletions, and conflating them is a daily annoyance: one lifts the clip and
    /// leaves the gap, the other closes it.
    func testRippleDeleteIsNotPlainDelete() {
        XCTAssertEqual(action("x"), .rippleDelete)
        XCTAssertEqual(action("\u{7F}"), .deleteSelection)
    }

    func testSplitIsOnItsUsualKey() {
        XCTAssertEqual(action("b", .command), .split)
    }

    func testUndoAndRedo() {
        XCTAssertEqual(action("z", .command), .undo)
        XCTAssertEqual(action("z", [.command, .shift]), .redo)
    }

    func testDigitsSetTheSelectedZoomLevel() {
        XCTAssertEqual(action("3"), .setZoomLevel(3))
        XCTAssertEqual(action("9"), .setZoomLevel(9))
    }

    /// **The rule that keeps the editor usable.** Every bare-key shortcut here is a letter someone
    /// might type into the transcript editor or a caption, so while a field has focus none of them
    /// may fire.
    func testBareKeysDoNothingWhileTextIsBeingEdited() {
        for key in [" ", "x", "l", "j", "k", "3"] {
            XCTAssertNil(action(key, editing: true), "\(key) fired while editing")
        }
    }

    /// …but the command-key ones still work, because that is what everybody expects of ⌘Z.
    func testCommandShortcutsStillWorkWhileEditingText() {
        XCTAssertEqual(action("z", .command, editing: true), .undo)
        XCTAssertEqual(action("s", .command, editing: true), .save)
    }

    func testAnUnboundKeyIsNotClaimed() {
        XCTAssertNil(action("q"))
    }

    // MARK: - Sources

    /// Raw values reach the project file, so renaming one silently orphans a saved recording.
    func testEverySourceHasAStableRawValue() {
        XCTAssertEqual(Set(RecordingSource.allCases.map(\.rawValue)),
                       ["display", "window", "area"])
    }

    func testEverySourceNamesItselfAndHasAGlyph() {
        for source in RecordingSource.allCases {
            XCTAssertFalse(source.title.isEmpty)
            XCTAssertFalse(source.symbolName.isEmpty)
        }
    }

    /// Only an area is aimed by dragging a rectangle, which is what decides whether the frozen
    /// overlay is shown at all.
    func testOnlyAnAreaIsAimedByDragging() {
        XCTAssertTrue(RecordingSource.area.aimsByDragging)
        XCTAssertFalse(RecordingSource.window.aimsByDragging)
        XCTAssertFalse(RecordingSource.display.aimsByDragging)
    }
}
