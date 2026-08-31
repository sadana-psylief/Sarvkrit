import XCTest
@testable import Sarvkrit

/// Stage 0 of the Files work split `Feature` into a UI-facing contract and `EventTapFeature`, and
/// added categories. These pin the parts the UI now depends on.
final class FeatureCategoryTests: XCTestCase {
    private let features = FeatureRegistry.makeAll()

    private func makeState(features: [Feature]) -> AppState {
        AppState(
            features: features,
            store: FeatureStore(defaults: UserDefaults(suiteName: "test.\(UUID())")!),
            permissions: PermissionsManager(),
            defaults: UserDefaults(suiteName: "test.\(UUID())")!
        )
    }

    func testEveryFeatureDeclaresACategory() {
        // The tray and sidebar both group by category; an uncategorised feature would silently
        // vanish from both rather than failing loudly.
        for feature in features {
            XCTAssertTrue(
                FeatureCategory.allCases.contains(feature.category),
                "\(feature.id) has an unknown category"
            )
        }
    }

    func testShippingFeaturesLandInTheExpectedCategories() {
        let byID = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0.category) })
        XCTAssertEqual(byID["finder-cut-paste"], .keyboard)
        XCTAssertEqual(byID["text-snippets"], .keyboard)
        XCTAssertEqual(byID["clipboard-history"], .clipboard)
        XCTAssertEqual(byID["quit-on-close"], .windows)
        XCTAssertEqual(byID["window-management"], .windows)
        XCTAssertEqual(byID["file-rules"], .files)
        XCTAssertEqual(byID["shelf"], .files)
        XCTAssertEqual(byID["audio-switcher"], .sound)
        XCTAssertEqual(byID["mute-microphone"], .sound)
        XCTAssertEqual(byID["keep-awake"], .system)
    }

    func testPopulatedCategoriesSkipEmptyOnesAndKeepDeclarationOrder() {
        // An empty category must not render as a header above nothing.
        let state = makeState(features: [CutPasteFeature()])
        XCTAssertEqual(state.populatedCategories, [.keyboard])
        XCTAssertFalse(state.populatedCategories.contains(.files))
        XCTAssertFalse(state.populatedCategories.contains(.clipboard))
    }

    func testPopulatedCategoriesFollowDeclarationOrderNotRegistrationOrder() {
        // Registered Files-first, but Keyboard is declared first and must display first.
        let state = makeState(features: [FileRulesFeature(), CutPasteFeature()])
        XCTAssertEqual(state.populatedCategories, [.keyboard, .files])
    }

    func testEveryFeatureAppearsInExactlyOneCategoryGrouping() {
        let state = makeState(features: features)
        let grouped = state.populatedCategories.flatMap { state.features(in: $0) }
        XCTAssertEqual(grouped.count, features.count, "a feature was dropped or double-counted")
        XCTAssertEqual(Set(grouped.map(\.id)), Set(features.map(\.id)))
    }

    // MARK: - The split itself

    func testEventTapFeaturesDeclareANonEmptyMask() {
        // A tap feature with an empty mask silently never runs — it would be added to the tap and
        // then see nothing.
        let tapFeatures = features.compactMap { $0 as? EventTapFeature }
        XCTAssertFalse(tapFeatures.isEmpty)
        for feature in tapFeatures {
            XCTAssertNotEqual(feature.eventMask, 0, "\(feature.id) subscribes to nothing")
        }
    }

    func testOnlyFeaturesThatNeedTheTapConformToIt() {
        // The split's whole point: folder-watching and trash features must not be dragged into the
        // event tap, and must not require Accessibility on its behalf.
        let tapIDs = Set(features.compactMap { ($0 as? EventTapFeature)?.id })
        XCTAssertEqual(tapIDs, ["finder-cut-paste", "text-snippets", "clipboard-history",
                                "quit-on-close", "window-management"])
    }

    func testAccessibilityIsRequiredByTapFeaturesAndOnlyThem() {
        // `requiresAccessibility` used to be a stored Bool; it's now derived from a Set, and the
        // permission gating in AppState still reads it. The split is the point: File Rules watches
        // folders and must run without an Accessibility grant.
        for feature in features {
            let needsIt = feature.requirements.contains(.accessibility)
            XCTAssertEqual(needsIt, feature.requiresAccessibility, "\(feature.id): derivation drifted")
            XCTAssertEqual(needsIt, feature is EventTapFeature, "\(feature.id): wrong requirement")
        }
    }

    func testFileRulesRunsWithoutAccessibility() {
        let files = FileRulesFeature()
        XCTAssertFalse(files.requiresAccessibility)
        XCTAssertFalse(files is EventTapFeature)
        XCTAssertEqual(files.category, .files)
    }

    func testOnlyFeaturesThatNeedOneSupplyACustomDetailPane() {
        // Returning nil keeps FeatureDetailView the single implementation for everything simple.
        // File Rules is the exception the extension point exists for: a rule list and editor can't
        // be expressed as title/toggle/prose.
        //
        // Asserted **per feature**, not per category. It used to be per category, which stopped
        // being expressible the moment Windows held both Quit on Close — a toggle and a sentence,
        // which is what the generic pane is for — and Window Management, which needs 41 shortcut
        // recorders and the ultrawide controls.
        MainActor.assumeIsolated {
            let needsOwnPane: Set<String> = [
                "clipboard-history", "file-rules", "trash-cleanup", "app-sweep", "keep-awake",
                "window-management", "text-snippets", "shelf", "audio-switcher",
                "mute-microphone",
            ]
            for feature in features {
                let custom = feature.makeDetailView()
                if needsOwnPane.contains(feature.id) {
                    XCTAssertNotNil(custom, "\(feature.id) needs its own pane")
                } else {
                    XCTAssertNil(custom, "\(feature.id) should use the generic pane")
                }
            }
        }
    }

    func testBothWindowsFeaturesCoexistWithDifferentPaneKinds() {
        // The specific case that broke the per-category rule: one category, two kinds of pane.
        MainActor.assumeIsolated {
            let windows = features.filter { $0.category == .windows }
            XCTAssertEqual(Set(windows.map(\.id)), ["quit-on-close", "window-management"])

            let panes = windows.map { ($0.id, $0.makeDetailView() != nil) }
            XCTAssertTrue(panes.contains { $0 == ("window-management", true) })
            XCTAssertTrue(panes.contains { $0 == ("quit-on-close", false) })
        }
    }
}
