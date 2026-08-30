import CoreGraphics
import XCTest
@testable import Sarvkrit

final class CutPasteRewriterTests: XCTestCase {
    private func input(
        keyCode: Int64,
        flags: CGEventFlags = .maskCommand,
        bundleID: String? = CutPasteRewriter.finderBundleID,
        cutPending: Bool = false,
        changeCountAtCut: Int? = nil,
        currentChangeCount: Int = 100,
        isTextFieldFocused: Bool = false
    ) -> CutPasteRewriter.Input {
        CutPasteRewriter.Input(
            keyCode: keyCode,
            flags: flags,
            frontmostBundleID: bundleID,
            cutPending: cutPending,
            changeCountAtCut: changeCountAtCut,
            currentChangeCount: currentChangeCount,
            isTextFieldFocused: isTextFieldFocused
        )
    }

    // MARK: - Scope

    func testCommandXInFinderRewritesToCopy() {
        XCTAssertEqual(CutPasteRewriter.action(for: input(keyCode: CutPasteRewriter.keyX)),
                       .rewriteCutToCopy)
    }

    func testCommandXOutsideFinderIsUntouched() {
        // ⌘X already cuts text everywhere. Touching it outside Finder would be a regression,
        // not a feature.
        let action = CutPasteRewriter.action(
            for: input(keyCode: CutPasteRewriter.keyX, bundleID: "com.apple.TextEdit")
        )
        XCTAssertEqual(action, .none)
    }

    func testCommandXDuringInlineRenameIsUntouched() {
        // Renaming a file is a text field inside Finder: ⌘X must still cut the text.
        let action = CutPasteRewriter.action(
            for: input(keyCode: CutPasteRewriter.keyX, isTextFieldFocused: true)
        )
        XCTAssertEqual(action, .none)
    }

    func testUnknownFrontmostAppIsUntouched() {
        XCTAssertEqual(
            CutPasteRewriter.action(for: input(keyCode: CutPasteRewriter.keyX, bundleID: nil)),
            .none
        )
    }

    // MARK: - Modifier discipline

    func testExtraModifiersAreUntouched() {
        // ⌘⌥V is already Finder's move and ⌘⇧V is paste-and-match-style. Hijacking either
        // would break behaviour the user may already rely on.
        for extra in [CGEventFlags.maskAlternate, .maskShift, .maskControl] {
            let action = CutPasteRewriter.action(for: input(
                keyCode: CutPasteRewriter.keyV,
                flags: [.maskCommand, extra],
                cutPending: true,
                changeCountAtCut: 100
            ))
            XCTAssertEqual(action, .none, "modifier \(extra.rawValue) should pass through")
        }
    }

    func testPlainXWithoutCommandIsUntouched() {
        XCTAssertEqual(
            CutPasteRewriter.action(for: input(keyCode: CutPasteRewriter.keyX, flags: [])),
            .none
        )
    }

    // MARK: - Paste behaviour

    func testCommandVWithPendingCutBecomesMove() {
        let action = CutPasteRewriter.action(for: input(
            keyCode: CutPasteRewriter.keyV,
            cutPending: true,
            changeCountAtCut: 100,
            currentChangeCount: 100
        ))
        XCTAssertEqual(action, .rewriteToMove)
    }

    func testCommandVWithoutPendingCutStaysACopy() {
        // ⌘C then ⌘V must keep copying — no regression on the normal path.
        let action = CutPasteRewriter.action(for: input(
            keyCode: CutPasteRewriter.keyV,
            cutPending: false,
            changeCountAtCut: 100,
            currentChangeCount: 100
        ))
        XCTAssertEqual(action, .none)
    }

    func testPasteboardChangedSinceCutStaysACopy() {
        // Something else claimed the pasteboard after the cut. Moving now would relocate a
        // file the user meant to duplicate.
        let action = CutPasteRewriter.action(for: input(
            keyCode: CutPasteRewriter.keyV,
            cutPending: true,
            changeCountAtCut: 100,
            currentChangeCount: 101
        ))
        XCTAssertEqual(action, .none)
    }

    func testPasteBeforeCutSampleLandsStaysACopy() {
        // The 150ms sample hasn't landed yet, so we can't prove the pasteboard still holds
        // the cut. Degrading to a copy is the safe direction to fail.
        let action = CutPasteRewriter.action(for: input(
            keyCode: CutPasteRewriter.keyV,
            cutPending: true,
            changeCountAtCut: nil,
            currentChangeCount: 100
        ))
        XCTAssertEqual(action, .none)
    }

    func testCutSampleTakenAfterFinderWroteIsTheOneThatMatters() {
        // Finder advanced the count from 100 to 101 while writing the cut; the sample
        // captured 101, so the following paste is still a valid move.
        let action = CutPasteRewriter.action(for: input(
            keyCode: CutPasteRewriter.keyV,
            cutPending: true,
            changeCountAtCut: 101,
            currentChangeCount: 101
        ))
        XCTAssertEqual(action, .rewriteToMove)
    }

    // MARK: - Hot-path pre-filter
    //
    // `isCandidate` gates the AX round-trip that determines `isTextFieldFocused`. If it ever
    // returns true too readily, every keystroke on the system pays for an IPC call.

    func testCandidateFilterAcceptsOnlyFinderCutAndPaste() {
        XCTAssertTrue(CutPasteRewriter.isCandidate(
            keyCode: CutPasteRewriter.keyX, flags: .maskCommand,
            frontmostBundleID: CutPasteRewriter.finderBundleID))
        XCTAssertTrue(CutPasteRewriter.isCandidate(
            keyCode: CutPasteRewriter.keyV, flags: .maskCommand,
            frontmostBundleID: CutPasteRewriter.finderBundleID))
    }

    func testCandidateFilterRejectsOrdinaryTyping() {
        // The common case: a letter with no modifiers, in some other app. This must cost
        // nothing beyond the comparison itself.
        XCTAssertFalse(CutPasteRewriter.isCandidate(
            keyCode: 0, flags: [], frontmostBundleID: "com.apple.TextEdit"))
        XCTAssertFalse(CutPasteRewriter.isCandidate(
            keyCode: CutPasteRewriter.keyX, flags: [],
            frontmostBundleID: CutPasteRewriter.finderBundleID))
        XCTAssertFalse(CutPasteRewriter.isCandidate(
            keyCode: CutPasteRewriter.keyX, flags: .maskCommand,
            frontmostBundleID: "com.apple.TextEdit"))
        XCTAssertFalse(CutPasteRewriter.isCandidate(
            keyCode: CutPasteRewriter.keyC, flags: .maskCommand,
            frontmostBundleID: CutPasteRewriter.finderBundleID))
        XCTAssertFalse(CutPasteRewriter.isCandidate(
            keyCode: CutPasteRewriter.keyV, flags: [.maskCommand, .maskAlternate],
            frontmostBundleID: CutPasteRewriter.finderBundleID))
    }

    func testCandidateFilterNeverRejectsSomethingActionWouldRewrite() {
        // The filter runs first, so anything it drops can never reach `action`. Prove the
        // two agree across the whole grid rather than trusting they were kept in sync.
        let keys: [Int64] = [0, CutPasteRewriter.keyX, CutPasteRewriter.keyC, CutPasteRewriter.keyV]
        let flagSets: [CGEventFlags] = [
            [], .maskCommand, [.maskCommand, .maskAlternate],
            [.maskCommand, .maskShift], .maskAlternate,
        ]
        let apps = [CutPasteRewriter.finderBundleID, "com.apple.TextEdit", nil]

        for key in keys {
            for flags in flagSets {
                for app in apps {
                    let action = CutPasteRewriter.action(for: input(
                        keyCode: key, flags: flags, bundleID: app,
                        cutPending: true, changeCountAtCut: 100, currentChangeCount: 100
                    ))
                    guard action != .none else { continue }
                    XCTAssertTrue(
                        CutPasteRewriter.isCandidate(keyCode: key, flags: flags, frontmostBundleID: app),
                        "filter would drop an event that action() rewrites: key \(key)"
                    )
                }
            }
        }
    }

    func testShapeTestRunsBeforeAnyAppLookup() {
        // The ordering IS the optimisation: `frontmostBundleID` is an @autoclosure, so for a key
        // that can't be ⌘X/⌘V the app must never be consulted. Proven by making the lookup record
        // that it ran — a comment claiming "cheap checks first" is what failed here before.
        var lookups = 0
        func frontmost() -> String? {
            lookups += 1
            return CutPasteRewriter.finderBundleID
        }

        _ = CutPasteRewriter.isCandidate(keyCode: 0, flags: [], frontmostBundleID: frontmost())
        XCTAssertEqual(lookups, 0, "an ordinary keystroke must not trigger a frontmost-app lookup")

        _ = CutPasteRewriter.isCandidate(
            keyCode: CutPasteRewriter.keyX, flags: .maskCommand, frontmostBundleID: frontmost())
        XCTAssertEqual(lookups, 1, "a ⌘X-shaped keystroke should consult the app exactly once")
    }

    func testOtherKeysAreUntouched() {
        for key in [Int64(0), CutPasteRewriter.keyC, 12] {
            XCTAssertEqual(CutPasteRewriter.action(for: input(keyCode: key)), .none)
        }
    }
}
