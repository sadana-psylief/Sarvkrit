import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The logic that decides where Restore puts a window back.
///
/// Extracted from the Accessibility glue precisely because a bug hid there: the applied frame was
/// never actually recorded, so the "don't overwrite the original" guard could never fire and
/// Restore returned a window to its *previous snap* rather than where the user had it.
final class RestoreMemoryTests: XCTestCase {
    private let free = CGRect(x: 300, y: 200, width: 700, height: 500)
    private let leftHalf = CGRect(x: 0, y: 0, width: 800, height: 1000)
    private let rightHalf = CGRect(x: 800, y: 0, width: 800, height: 1000)

    func testRestoringAfterOneSnapReturnsTheOriginalFrame() {
        var memory = RestoreMemory<Int>()
        memory.record(1, current: free, target: leftHalf)
        XCTAssertEqual(memory.restoreFrame(for: 1), free)
    }

    func testTwoSnapsInARowStillRestoreToTheOriginalFrame() {
        // The bug this file exists for. Snap left, then right: without the guard, the second snap
        // records the left half as "where the user had it" and Restore stops working.
        var memory = RestoreMemory<Int>()
        memory.record(1, current: free, target: leftHalf)
        memory.record(1, current: leftHalf, target: rightHalf)

        XCTAssertEqual(memory.restoreFrame(for: 1), free, "should still be the pre-snap frame")
    }

    func testAWholeChainOfSnapsKeepsTheOriginal() {
        var memory = RestoreMemory<Int>()
        var at = free
        for target in [leftHalf, rightHalf, leftHalf, rightHalf] {
            memory.record(1, current: at, target: target)
            at = target
        }
        XCTAssertEqual(memory.restoreFrame(for: 1), free)
    }

    func testMovingAWindowByHandStartsANewRestorePoint() {
        // If the user drags the window somewhere themselves, *that* is where they want to go back
        // to — not wherever it was before the snap they've since abandoned.
        var memory = RestoreMemory<Int>()
        memory.record(1, current: free, target: leftHalf)

        let draggedThere = CGRect(x: 50, y: 60, width: 400, height: 300)
        memory.record(1, current: draggedThere, target: rightHalf)

        XCTAssertEqual(memory.restoreFrame(for: 1), draggedThere)
    }

    func testAnAppThatQuantizesItsSizeStillCountsAsUnmoved() {
        // Terminal rounds to whole character cells, so it never lands exactly where it was put.
        // Without tolerance, every snap in Terminal would look user-initiated and Restore would
        // degrade to "undo the last snap".
        var memory = RestoreMemory<Int>()
        memory.record(1, current: free, target: leftHalf)

        let quantized = CGRect(x: leftHalf.minX + 3, y: leftHalf.minY,
                               width: leftHalf.width - 4, height: leftHalf.height - 6)
        memory.record(1, current: quantized, target: rightHalf)

        XCTAssertEqual(memory.restoreFrame(for: 1), free)
    }

    func testAWindowWeHaveNeverSeenHasNothingToRestoreTo() {
        // Restore must do nothing rather than guess a frame.
        XCTAssertNil(RestoreMemory<Int>().restoreFrame(for: 99))
    }

    func testWindowsAreTrackedIndependently() {
        var memory = RestoreMemory<Int>()
        let otherFree = CGRect(x: 10, y: 20, width: 300, height: 400)
        memory.record(1, current: free, target: leftHalf)
        memory.record(2, current: otherFree, target: rightHalf)

        XCTAssertEqual(memory.restoreFrame(for: 1), free)
        XCTAssertEqual(memory.restoreFrame(for: 2), otherFree)
    }

    func testRestoringTwiceDoesNotMoveTheWindowAgain() {
        // After a restore the window sits at its original frame. If that weren't recorded as
        // "applied", the next snap would treat it as a fresh user position — harmless — but a
        // second restore followed by a snap would lose the original.
        var memory = RestoreMemory<Int>()
        memory.record(1, current: free, target: leftHalf)
        memory.markRestored(1)

        memory.record(1, current: free, target: rightHalf)
        XCTAssertEqual(memory.restoreFrame(for: 1), free)
    }

    func testForgettingClearsEverything() {
        var memory = RestoreMemory<Int>()
        memory.record(1, current: free, target: leftHalf)
        memory.removeAll()
        XCTAssertEqual(memory.count, 0)
        XCTAssertNil(memory.restoreFrame(for: 1))
    }
}
