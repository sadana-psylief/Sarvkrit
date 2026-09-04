import Carbon.HIToolbox
import XCTest
@testable import Sarvkrit

/// The capture shortcuts, checked against the app's own policy and against every other family of
/// shortcuts it already ships. A default that collides is a default that silently breaks something
/// the user already relies on.
final class ScreenshotShortcutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    func testEveryActionHasADistinctHotkeyID() {
        // Carbon identifies hot keys by signature plus id, so two sharing one collide and only one
        // ever fires — with nothing to see but a shortcut that stopped working.
        let ids = ScreenshotAction.allCases.map(\.hotkeyID)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testNoCaptureHotkeyIDCollidesWithAnExistingOne() {
        let existing: Set<UInt32> = [GlobalHotkey.ID.shelf,
                                     GlobalHotkey.ID.audioCycle,
                                     GlobalHotkey.ID.micMute]
        for action in ScreenshotAction.allCases {
            XCTAssertFalse(existing.contains(action.hotkeyID),
                           "\(action.rawValue) reuses an id already in the app")
        }
    }

    func testEveryDefaultIsDistinct() {
        let shortcuts = ScreenshotAction.allCases.map(\.defaultShortcut)
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count)
    }

    func testEveryDefaultPassesTheRecordersOwnPolicy() {
        let defaults = ScreenshotAction.defaults
        for action in ScreenshotAction.allCases {
            let verdict = ShortcutConflict.verdict(
                for: action.defaultShortcut, existing: defaults, assigningTo: action)
            XCTAssertTrue(verdict.isAllowed,
                          "\(action.rawValue): \(verdict.message ?? "refused")")
            XCTAssertEqual(verdict, .available,
                           "\(action.rawValue) should be free: \(verdict.message ?? "")")
        }
    }

    func testNoCaptureDefaultCollidesWithARectangleDefault() {
        let window = Set(WindowShortcutStore.rectangleDefaults.values)
        for action in ScreenshotAction.allCases {
            XCTAssertFalse(window.contains(action.defaultShortcut),
                           "\(action.rawValue) takes a window-management binding")
        }
    }

    func testNoCaptureDefaultCollidesWithTheClipboardOrTheShelf() {
        for action in ScreenshotAction.allCases {
            let shortcut = action.defaultShortcut
            XCTAssertNil(ClipboardHotkey.match(keyCode: shortcut.keyCode, flags: shortcut.flags),
                         "\(action.rawValue) takes a clipboard binding")
            // The Shelf is ⌃⌥S, registered with Carbon.
            XCTAssertFalse(shortcut.keyCode == Int64(kVK_ANSI_S)
                           && shortcut.flags == [.maskControl, .maskAlternate],
                           "\(action.rawValue) takes the Shelf's shortcut")
        }
    }

    func testTheSystemScreenshotKeysAreFlaggedButNotRefused() {
        // ⌘⇧4. Warned rather than refused, on the same principle as the clipboard conflicts: the
        // user may prefer ours, but must not discover later that it silently never fires.
        let verdict = ShortcutConflict.verdict(
            for: WindowShortcut(keyCode: 21, modifiers: [.maskCommand, .maskShift]),
            existing: ScreenshotAction.defaults, assigningTo: .area)
        XCTAssertTrue(verdict.isAllowed)
        XCTAssertEqual(verdict, .conflictsWithFeature("the macOS screenshot shortcuts"))
    }

    func testBindingAnInUseCombinationTakesItFromTheOtherAction() {
        let store = ScreenshotShortcutStore(defaults: defaults)
        let windowShortcut = try! XCTUnwrap(store.shortcut(for: .window))
        store.bind(.fullscreen, to: windowShortcut)
        XCTAssertNil(store.shortcut(for: .window), "two actions must not share one key")
        XCTAssertEqual(store.shortcut(for: .fullscreen), windowShortcut)
    }

    func testAClearedBindingSurvivesAReload() {
        // The reason the whole map is persisted rather than only the changes: if an absent key
        // meant "use the default", a cleared binding would come back on next launch.
        let store = ScreenshotShortcutStore(defaults: defaults)
        store.bind(.area, to: nil)
        XCTAssertNil(ScreenshotShortcutStore(defaults: defaults).shortcut(for: .area))
    }

    func testARebindSurvivesAReload() {
        let store = ScreenshotShortcutStore(defaults: defaults)
        let custom = WindowShortcut(keyCode: Int64(kVK_ANSI_B),
                                    modifiers: [.maskCommand, .maskControl])
        store.bind(.area, to: custom)
        XCTAssertEqual(ScreenshotShortcutStore(defaults: defaults).shortcut(for: .area), custom)
    }

    func testAnUnknownStoredActionIsDroppedWithoutLosingTheRest() {
        // Removing a mode in a later version must not reset every binding the user made.
        let store = ScreenshotShortcutStore(defaults: defaults)
        let custom = WindowShortcut(keyCode: Int64(kVK_ANSI_B), modifiers: [.maskControl])
        store.bind(.area, to: custom)

        var raw = try! JSONDecoder().decode(
            [String: WindowShortcut].self,
            from: defaults.data(forKey: "screenshot.shortcuts")!)
        raw["holographic"] = WindowShortcut(keyCode: 99, modifiers: [.maskControl])
        defaults.set(try! JSONEncoder().encode(raw), forKey: "screenshot.shortcuts")

        let reloaded = ScreenshotShortcutStore(defaults: defaults)
        XCTAssertEqual(reloaded.shortcut(for: .area), custom)
    }

    func testMatchFindsTheActionForACombination() {
        let bindings = ScreenshotAction.defaults
        let area = bindings[.area]!
        XCTAssertEqual(
            ScreenshotShortcutStore.match(keyCode: area.keyCode, flags: area.flags, in: bindings),
            .area)
        XCTAssertNil(ScreenshotShortcutStore.match(keyCode: 999, flags: [], in: bindings))
    }

    func testResettingRestoresEveryDefault() {
        let store = ScreenshotShortcutStore(defaults: defaults)
        store.bind(.area, to: nil)
        store.resetToDefaults()
        XCTAssertEqual(store.shortcut(for: .area), ScreenshotAction.area.defaultShortcut)
    }
}

/// The merge rules that decide which shortcuts exist after an upgrade.
final class ScreenshotShortcutMergeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    func testAnActionAddedInALaterVersionGetsItsDefault() {
        // The bug this rule exists for: an action simply absent from the stored map used to mean
        // "cleared", so any shortcut introduced later would silently never register for anyone who
        // had ever changed a binding — which is everyone who has used the recorder once.
        let store = ScreenshotShortcutStore(defaults: defaults)
        store.bind(.area, to: WindowShortcut(keyCode: 11, modifiers: [.maskControl, .maskCommand]))

        // Simulate an older build's stored map: it knows nothing about `.history`.
        var raw = try! JSONDecoder().decode(
            [String: WindowShortcut].self,
            from: defaults.data(forKey: "screenshot.shortcuts")!)
        raw.removeValue(forKey: "history")
        defaults.set(try! JSONEncoder().encode(raw), forKey: "screenshot.shortcuts")

        let reloaded = ScreenshotShortcutStore(defaults: defaults)
        XCTAssertEqual(reloaded.shortcut(for: .history), ScreenshotAction.history.defaultShortcut,
                       "a new action must fall back to its default")
        XCTAssertEqual(reloaded.shortcut(for: .area)?.keyCode, 11, "and a rebind must survive")
    }

    func testAClearedBindingStaysClearedAcrossReloads() {
        // The other half: defaults filling in must not resurrect something deliberately removed.
        let store = ScreenshotShortcutStore(defaults: defaults)
        store.bind(.scrolling, to: nil)
        XCTAssertNil(ScreenshotShortcutStore(defaults: defaults).shortcut(for: .scrolling))
    }

    func testRebindingAClearedActionUnclearsIt() {
        let store = ScreenshotShortcutStore(defaults: defaults)
        store.bind(.scrolling, to: nil)
        // Deliberately a combination no default already owns: ⌃⇧Y belongs to Browse Captures,
        // and picking it here had the de-duplication drop one of the two — correctly, but it made
        // the test look like a bug in unclearing.
        let custom = WindowShortcut(keyCode: 11, modifiers: [.maskControl, .maskShift])
        store.bind(.scrolling, to: custom)
        XCTAssertEqual(ScreenshotShortcutStore(defaults: defaults).shortcut(for: .scrolling),
                       custom)
    }

    func testMergingNeverLeavesTwoActionsOnOneKey() {
        // Filling in defaults can collide with a rebind that took that very combination.
        let store = ScreenshotShortcutStore(defaults: defaults)
        store.bind(.area, to: ScreenshotAction.window.defaultShortcut)

        let reloaded = ScreenshotShortcutStore(defaults: defaults)
        let shortcuts = reloaded.bindings.values
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count,
                       "two actions share a combination after merging")
    }

    func testResetClearsTheClearedSetToo() {
        let store = ScreenshotShortcutStore(defaults: defaults)
        store.bind(.scrolling, to: nil)
        store.resetToDefaults()
        XCTAssertEqual(ScreenshotShortcutStore(defaults: defaults).shortcut(for: .scrolling),
                       ScreenshotAction.scrolling.defaultShortcut)
    }
}
