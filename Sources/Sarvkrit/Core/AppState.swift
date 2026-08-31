import AppKit
import Combine
import Foundation
import SwiftUI

/// Owns everything and keeps three things in agreement: what the user switched on, whether
/// Accessibility is granted, and which features the event tap is actually running.
///
/// `sync()` is the single place that reconciles them, so there is exactly one code path to
/// reason about when a toggle flips, when permission is granted, and when it's revoked.
final class AppState: ObservableObject {
    /// A singleton on purpose. When the user has hidden the menu bar icon there is no scene
    /// and no view has ever appeared, yet `applicationShouldHandleReopen` still has to be
    /// able to open the window — that relaunch is the only way back into the app. Wiring
    /// state in from `onAppear` would leave exactly that path dead.
    static let shared = AppState()

    let features: [Feature]
    let store: FeatureStore
    let permissions: PermissionsManager
    private let tap = EventTapService()

    /// A feature the user enabled that isn't actually running. In practice this means
    /// Accessibility is missing; the UI uses it to disable controls rather than let someone
    /// flip a switch that silently does nothing.
    /// Derived state, recomputed by `sync()`. Not `@Published` — `sync()` announces it explicitly
    /// and only when it actually changes, which keeps one user action to one notification.
    private(set) var blockedFeatureIDs: Set<String> = []

    // MARK: - User-writable state
    //
    // These are hand-rolled instead of `@Published` for one specific reason: `@Published`
    // notifies on *every* write, including a write of the value the property already holds.
    // SwiftUI writes back through two-way bindings — `MenuBarExtra(isInserted:)`,
    // `Toggle(isOn:)` — as an ordinary part of an update pass, so a same-value write became
    // notify → invalidate → update → write back → notify, a loop that never reached a fixed
    // point and pinned a core at 100% until the app was killed.
    //
    // The guard has to live in the setter, not in `didSet`: by the time `didSet` runs,
    // `@Published` has already published. Same-value writes must be genuinely inert.

    var showMenuBarIcon: Bool {
        get { storedShowMenuBarIcon }
        set {
            guard newValue != storedShowMenuBarIcon else { return }
            objectWillChange.send()
            storedShowMenuBarIcon = newValue
            defaults.set(newValue, forKey: Self.menuBarIconKey)
        }
    }

    var launchAtLogin: Bool {
        get { storedLaunchAtLogin }
        set {
            guard newValue != storedLaunchAtLogin else { return }
            objectWillChange.send()
            // Only now does the XPC to the login-item daemon happen. Reading
            // SMAppService.status on every write — which the old didSet did — put a
            // cross-process round trip inside the render loop.
            storedLaunchAtLogin = LaunchAtLogin.set(newValue)
        }
    }

    /// First run, or permission revoked: the window opens on onboarding instead of a feature.
    var hasCompletedOnboarding: Bool {
        get { storedHasCompletedOnboarding }
        set {
            guard newValue != storedHasCompletedOnboarding else { return }
            objectWillChange.send()
            storedHasCompletedOnboarding = newValue
            defaults.set(newValue, forKey: Self.onboardingKey)
        }
    }

    /// Which tray tab to open on. Persisted so the panel comes back where it was left.
    ///
    /// Hand-rolled like the rest of the user-writable state here: SwiftUI writes back through
    /// two-way bindings routinely, and a plain `@Published` republishes on same-value writes —
    /// which is what pinned a CPU core earlier in this project.
    var selectedTrayTabID: String? {
        get { storedSelectedTrayTabID }
        set {
            guard newValue != storedSelectedTrayTabID else { return }
            objectWillChange.send()
            storedSelectedTrayTabID = newValue
            defaults.set(newValue, forKey: Self.trayTabKey)
        }
    }

    private var storedSelectedTrayTabID: String?
    private var storedShowMenuBarIcon: Bool
    private var storedLaunchAtLogin: Bool
    private var storedHasCompletedOnboarding: Bool

    private static let menuBarIconKey = "showMenuBarIcon"
    private static let onboardingKey = "hasCompletedOnboarding"
    private static let trayTabKey = "selectedTrayTab"
    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    init(
        features: [Feature] = FeatureRegistry.makeAll(),
        store: FeatureStore = FeatureStore(),
        permissions: PermissionsManager = PermissionsManager(),
        defaults: UserDefaults = .standard
    ) {
        self.features = features
        self.store = store
        self.permissions = permissions
        self.defaults = defaults
        self.storedShowMenuBarIcon = defaults.object(forKey: Self.menuBarIconKey) as? Bool ?? true
        self.storedHasCompletedOnboarding = defaults.bool(forKey: Self.onboardingKey)
        self.storedSelectedTrayTabID = defaults.string(forKey: Self.trayTabKey)
        // Read once at startup. After this the value only changes when the user changes it,
        // and the setter is what talks to SMAppService.
        self.storedLaunchAtLogin = LaunchAtLogin.isEnabled

        // The permission poll does double duty: it updates the checkmark AND retries
        // activation. tapCreate fails outright while untrusted, so without this a user who
        // grants access sees nothing happen until they relaunch.
        permissions.onTrustChanged = { [weak self] _ in self?.sync() }
        permissions.startMonitoring()

        // SwiftUI does not observe *through* a nested ObservableObject: a view holding
        // AppState never hears about `permissions.isTrusted` changing on its own. Forwarding
        // this is what makes the onboarding checkmark flip live the moment access is granted,
        // rather than on the next unrelated redraw.
        //
        // The store is NOT forwarded: every write to it goes through `setEnabled` below, which
        // notifies once itself. Forwarding as well made a single toggle publish twice.
        permissions.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        sync()
    }

    /// Categories that actually contain something, in declaration order. Drives both the tray's
    /// modules and the sidebar's sections, so the two can never disagree.
    var populatedCategories: [FeatureCategory] {
        FeatureCategory.allCases.filter { category in
            features.contains { $0.category == category }
        }
    }

    /// The tray's tabs: every populated category, then General.
    var trayTabs: [TrayTab] {
        TrayTab.tabs(for: populatedCategories)
    }

    func features(in category: FeatureCategory) -> [Feature] {
        features.filter { $0.category == category }
    }

    deinit {
        // Features hold watchers and timers of their own; dropping AppState without stopping them
        // would leak them for the life of the process.
        features.forEach { $0.deactivate() }
        permissions.stopMonitoring()
    }

    func feature(withID id: String) -> Feature? {
        features.first { $0.id == id }
    }

    func isEnabled(_ feature: Feature) -> Bool {
        store.isEnabled(feature.id)
    }

    func isBlocked(_ feature: Feature) -> Bool {
        blockedFeatureIDs.contains(feature.id)
    }

    /// A binding for a feature's toggle, built **fresh on every call**.
    ///
    /// These were cached once, one shared `Binding` per feature — and that was the bug where a
    /// toggle read as off again after reopening the tray. A `Binding` carries change-tracking
    /// identity, and the tray row and the window's detail pane are independent SwiftUI view trees;
    /// handing both the same long-lived binding let a rebuilt view reassert what it last held.
    ///
    /// The caching came from an unmeasured "optimisation". A few closure allocations per render on
    /// a five-row panel are not worth a toggle that lies about its own state.
    func binding(for feature: Feature) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.store.isEnabled(feature.id) ?? false },
            set: { [weak self] value in self?.setEnabled(feature, value) }
        )
    }

    /// The one place a feature's enabled state changes, and therefore the one place that
    /// announces it. Exactly one notification per user action.
    func setEnabled(_ feature: Feature, _ enabled: Bool) {
        guard store.isEnabled(feature.id) != enabled else { return }
        objectWillChange.send()
        store.setEnabled(feature.id, enabled)
        sync()
    }

    /// Rebuild the event tap because a feature's *mask* changed, rather than its enabled state.
    ///
    /// Window Management subscribes to mouse events only while snap-by-dragging is on —
    /// `leftMouseDragged` fires for every drag on the system, so it isn't something to listen for
    /// speculatively. Changing that option has to reach the tap, and nothing else here would.
    func resyncEventTap() {
        sync()
    }

    /// True when at least one enabled feature needs a permission we don't have.
    var needsAccessibility: Bool {
        !permissions.isTrusted && features.contains { store.isEnabled($0.id) && $0.requiresAccessibility }
    }

    private func sync() {
        let wanted = features.filter { store.isEnabled($0.id) }
        let runnable = wanted.filter { permissions.isTrusted || !$0.requiresAccessibility }

        // Rebuild from scratch rather than diffing: there is one tap, its mask is the union
        // of its subscribers, and any change to the set means a new mask anyway.
        for feature in features { feature.deactivate() }

        // Only features that actually consume input events reach the tap. A folder-watching
        // feature has no event mask and simply activates.
        let tapFeatures = runnable.compactMap { $0 as? EventTapFeature }
        let started = tapFeatures.isEmpty || tap.setSubscribers(tapFeatures)
        if started {
            runnable.forEach { $0.activate() }
        } else {
            // The tap failed, so tap-driven features are blocked — but features that don't need
            // it are unaffected and should still run.
            runnable.filter { !($0 is EventTapFeature) }.forEach { $0.activate() }
        }

        let unrunnable = Set(wanted.map(\.id)).subtracting(runnable.map(\.id))
        let blocked = started
            ? unrunnable
            : unrunnable.union(wanted.filter { $0 is EventTapFeature }.map(\.id))

        // Announce a real change. This used to be updated silently on the theory that whoever
        // called sync() had already published — but the trust-change path moves it with no user
        // action at all, so rows kept showing a feature as running while it was actually blocked.
        // Guarded on inequality, so an unchanged set still costs nothing.
        if blocked != blockedFeatureIDs {
            objectWillChange.send()
            blockedFeatureIDs = blocked
        }
    }
}
