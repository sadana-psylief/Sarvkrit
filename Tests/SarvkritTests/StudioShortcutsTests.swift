import XCTest
@testable import Sarvkrit

/// The list the editor shows when you press ⌘/.
///
/// **⌘/ was routed to `break`.** It was recognised, deliberately silent, and therefore the one
/// discoverability hatch the editor had was nailed shut — which is why "add a zoom by hand", which
/// has worked all along behind an unlabelled glyph and the `Z` key, was reported as missing.
///
/// This list is a plain value so it can be checked against the router rather than drifting from it.
final class StudioShortcutsTests: XCTestCase {

    /// **Every shortcut listed must actually do something.** A list that promises a key the router
    /// ignores is worse than no list.
    func testEveryListedShortcutIsRouted() {
        for entry in StudioShortcuts.all where !entry.isUnavailable {
            XCTAssertNotNil(
                StudioKeyRouting.action(forCharacters: entry.characters,
                                        modifiers: entry.modifiers,
                                        isEditingText: false),
                "\(entry.title) is listed as \(entry.keyLabel) but the router ignores it")
        }
    }

    /// And the two that are honestly not built say so, rather than being quietly left out.
    func testTheUnbuiltCommandsAreListedAsUnavailable() {
        let unavailable = StudioShortcuts.all.filter(\.isUnavailable).map(\.title)
        XCTAssertTrue(unavailable.contains { $0.contains("In") })
        XCTAssertTrue(unavailable.contains { $0.contains("Out") })
    }

    /// The things people could not find are in there.
    func testTheHardToFindActionsAreListed() {
        let titles = StudioShortcuts.all.map(\.title)
        XCTAssertTrue(titles.contains { $0.localizedCaseInsensitiveContains("zoom") })
        XCTAssertTrue(titles.contains { $0.localizedCaseInsensitiveContains("play") })
        XCTAssertTrue(titles.contains { $0.localizedCaseInsensitiveContains("split") })
    }

    func testEntriesAreGrouped() {
        XCTAssertFalse(StudioShortcuts.groups.isEmpty)
        XCTAssertEqual(StudioShortcuts.groups.flatMap(\.entries).count, StudioShortcuts.all.count)
    }
}
