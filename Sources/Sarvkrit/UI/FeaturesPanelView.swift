import SwiftUI

/// Every feature in the app as a switch, grouped by category.
///
/// This is what the whole menu bar panel used to be: one tab per category, each holding that
/// category's switches. Making the panel a dashboard moved the live things to panels of their own
/// and left the switches without a home, and they need one — several features have nothing to show
/// and exist only as a switch, and turning something on is otherwise a trip to the main window.
///
/// So the switchboard survives as a single panel rather than as the shape of the whole thing. It is
/// also the one place a *blocked* feature can explain itself: a feature whose permission was
/// revoked contributes no panel, so this is where it says what it is missing.
struct FeaturesPanelView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                ForEach(app.populatedCategories) { category in
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        SectionHeader(category.title)
                        SettingsModule {
                            let features = app.features(in: category)
                            ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                                if index > 0 { ModuleSeparator() }
                                FeatureRow(
                                    feature: feature,
                                    isOn: app.binding(for: feature),
                                    isBlocked: app.isBlocked(feature),
                                    blockedReason: app.blockingRequirement(for: feature)
                                        .map { "Needs \($0.title)" }
                                )
                            }
                        }
                    }
                }
            }
            // Room for the scroller so it never sits on top of a switch.
            .padding(.trailing, Theme.Space.xs)
        }
        // `fixedSize` on the vertical axis would defeat the cap; this asks for the natural height
        // and stops at the ceiling, so short lists don't get a scroller they didn't need.
        .frame(maxHeight: Theme.Size.panelMaxContentHeight)
    }
}
