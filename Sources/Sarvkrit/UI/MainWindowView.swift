import SwiftUI

enum SidebarItem: Hashable {
    case onboarding
    case feature(String)
    case general
    case about
}

/// The full window: features in the sidebar, a grouped `Form` in the detail pane. Stock
/// `NavigationSplitView` + `.formStyle(.grouped)` is what gives it System Settings' look
/// without any custom drawing.
struct MainWindowView: View {
    @EnvironmentObject private var app: AppState
    @State private var selection: SidebarItem?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if showOnboarding {
                    Section {
                        Label("Set Up Sarvkrit", systemImage: "hand.wave")
                            .tag(SidebarItem.onboarding)
                    }
                }
                ForEach(app.populatedCategories) { category in
                    Section(category.title) {
                        ForEach(app.features(in: category), id: \.id) { feature in
                            Label(feature.title, systemImage: feature.symbolName)
                                .tag(SidebarItem.feature(feature.id))
                        }
                    }
                }
                Section("General") {
                    Label("Settings", systemImage: "gearshape")
                        .tag(SidebarItem.general)
                    Label("About", systemImage: "info.circle")
                        .tag(SidebarItem.about)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
        }
        .frame(
            minWidth: Theme.Size.windowMin.width,
            minHeight: Theme.Size.windowMin.height
        )
        .onAppear { selection = selection ?? defaultSelection }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? defaultSelection {
        case .onboarding:
            OnboardingView { selection = app.features.first.map { .feature($0.id) } }
        case .feature(let id):
            if let feature = app.feature(withID: id) {
                FeatureDetailView(feature: feature)
            } else {
                ContentUnavailableView("Feature not found", systemImage: "questionmark.folder")
            }
        case .general:
            GeneralSettingsView()
        case .about:
            AboutView()
        }
    }

    /// Onboarding isn't a modal gate — it's just the first thing selected when there's
    /// nothing granted yet, so the user can navigate away and come back.
    ///
    /// **Accessibility only, deliberately.** The obvious change once a second queryable grant
    /// exists is to add `|| !permissions.canCaptureScreen` here — don't. Accessibility gates most
    /// of the app, so its absence really is the first thing to deal with; Screen Recording gates
    /// one category, and letting it hijack the window into onboarding would ambush someone who
    /// opened Settings to change a clipboard option. The per-feature banner already covers it.
    private var showOnboarding: Bool {
        !app.hasCompletedOnboarding || !app.permissions.isTrusted
    }

    private var defaultSelection: SidebarItem {
        if showOnboarding { return .onboarding }
        return app.features.first.map { .feature($0.id) } ?? .general
    }
}
