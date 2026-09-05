import SwiftUI

enum SidebarItem: Hashable {
    case onboarding
    case feature(String)
    case general
    case about

    /// Names for the panes another part of the app can ask the window to open on. Strings rather
    /// than the enum itself because `AppState` is in Core and must not depend on the UI layer.
    static let generalID = "general"
    static let aboutID = "about"
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
        .onAppear {
            selection = selection ?? defaultSelection
            // Opening the window is one of the four moments the update feed is re-read. The
            // window is built once and reused, so onAppear alone would only fire the first time;
            // MainWindowController.show() covers every later open.
            app.updates.refresh()
            consumePendingSelection()
        }
        .onChange(of: app.pendingSidebarSelection) { _, _ in consumePendingSelection() }
    }

    /// The menu bar panel cannot show a sheet — it dismisses as focus moves — so the update
    /// banner opens this window on a named pane instead. The request is consumed once and
    /// cleared, so re-opening the window later lands wherever the user last was.
    private func consumePendingSelection() {
        guard let requested = app.pendingSidebarSelection else { return }
        if requested == SidebarItem.generalID { selection = .general }
        if requested == SidebarItem.aboutID { selection = .about }
        app.pendingSidebarSelection = nil
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
