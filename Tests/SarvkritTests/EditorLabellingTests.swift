import AppKit
import SwiftUI
import XCTest
@testable import Sarvkrit

/// Every tool says what it is.
///
/// "Other features in that annotation place is not clear." The tooltips were already there — a
/// tooltip is a fallback, not a label — and the editor's tool button was a copy of the capture
/// bar's cell with the visible text taken out. These assert the text is back, so the next tool
/// added cannot quietly ship as a bare glyph.
@MainActor
final class EditorLabellingTests: XCTestCase {

    func testEveryToolHasAName() {
        for tool in ToolKind.allCases {
            XCTAssertFalse(tool.title.isEmpty, "\(tool) has no title to show")
            XCTAssertFalse(tool.symbolName.isEmpty, "\(tool) has no symbol")
        }
    }

    func testEveryToolNameIsShortEnoughToSitUnderAnIcon() {
        // A long word forces the button wide and pushes the palette off the window, which is the
        // failure this labelling caused the first time and had to be designed around.
        for tool in ToolKind.allCases {
            XCTAssertLessThanOrEqual(tool.title.count, 12,
                                     "\(tool.title) is too long for a toolbar label")
        }
    }

    func testToolNamesAreDistinct() {
        let titles = ToolKind.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two tools share a name: \(titles)")
    }

    func testTheArrowStylesAreNamedIndividually() {
        // All four buttons shared one tooltip, "Arrow style", which said nothing about which was
        // which — the thing a person is trying to work out when they look at four similar shapes.
        let titles = ArrowElement.Head.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, 4, "arrow styles share names: \(titles)")
        XCTAssertFalse(titles.contains { $0.isEmpty })
    }

    /// The named tool row fits the editor's minimum window width.
    ///
    /// Measured from the labels rather than by rendering: SwiftUI only realises the part of a
    /// `ScrollView` it has laid out, so an accessibility walk reports whichever tools happen to be
    /// on screen and calls the rest missing. Summing the widths is deterministic, and it is the
    /// actual failure to guard — the first attempt at labelling pushed half the palette out of
    /// sight, which is the same "I could not find it" the labels were added to fix.
    func testTheNamedToolRowFitsTheMinimumWindowWidth() {
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        func buttonWidth(_ title: String) -> CGFloat {
            let text = (title as NSString).size(withAttributes: [.font: font]).width
            return max(46, text + 10)          // matches the button's minWidth and padding
        }

        var total = ToolKind.allCases.reduce(0) { $0 + buttonWidth($1.title) }
        total += buttonWidth("Background")
        // Four group containers, each with 2pt padding a side, and 10pt between the groups.
        total += 4 * 4 + 4 * 10
        // The window's own margins either side of the toolbar.
        total += 32

        XCTAssertLessThanOrEqual(total, ScreenshotEditorWindowController.minimumWidth,
                                 "the tool row needs \(Int(total))pt but the window can be "
                                 + "\(Int(ScreenshotEditorWindowController.minimumWidth))pt wide, "
                                 + "so tools would scroll out of sight")
    }
}
