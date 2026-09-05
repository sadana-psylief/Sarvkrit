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
    let updates: UpdateChecker
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

    /// Whether the update check is actually running in the background.
    ///
    /// This reads and writes the *achieved* state, not the requested one. A user can refuse the
    /// background item in System Settings, after which `register()` does nothing — and a switch
    /// sitting ON while nothing runs is the worst possible outcome for a feature whose whole job
    /// is telling you about updates. `UpdateCheckAgent.needsApproval` is what the pane shows
    /// alongside it to explain a refusal.
    var automaticUpdateChecks: Bool {
        get { storedAutomaticUpdateChecks }
        set {
            guard newValue != storedAutomaticUpdateChecks else { return }
            objectWillChange.send()
            // Intent is recorded separately and first, so it survives a refusal. Stored as its
            // negative so that "on" is the absence of a key: the feature ships enabled, and that
            // way it needs no first-run migration for anyone upgrading from a build without it.
            storedWantsAutomaticUpdateChecks = newValue
            defaults.set(!newValue, forKey: Self.updateChecksDisabledKey)
            // Only now the XPC to the background-item daemon, never in a getter — same reason as
            // `launchAtLogin` above. What comes back is what was achieved.
            storedAutomaticUpdateChecks = UpdateCheckAgent.set(newValue)
        }
    }

    /// What the user asked for, as distinct from what happened.
    ///
    /// The launch-time reconcile needs this: without it there is no way to tell "never registered
    /// yet" from "switched off on purpose", and the app would quietly turn the check back on for
    /// someone who had just turned it off.
    var wantsAutomaticUpdateChecks: Bool { storedWantsAutomaticUpdateChecks }

    /// Re-read the agent's real status. Called after `AppDelegate` reconciles at launch, since
    /// registering there would otherwise leave this switch showing the pre-launch answer.
    func refreshUpdateAgentStatus() {
        let achieved = UpdateCheckAgent.isEnabled
        guard achieved != storedAutomaticUpdateChecks else { return }
        objectWillChange.send()
        storedAutomaticUpdateChecks = achieved
    }

    /// Where the main window should open next. Consumed and cleared by `MainWindowView`.
    ///
    /// The update banner lives in the menu bar panel, which cannot show a sheet — the panel
    /// dismisses as focus moves — so it has to open the window on a specific pane instead.
    var pendingSidebarSelection: String? {
        get { storedPendingSidebarSelection }
        set {
            guard newValue != storedPendingSidebarSelection else { return }
            objectWillChange.send()
            storedPendingSidebarSelection = newValue
        }
    }

    private var storedAutomaticUpdateChecks: Bool
    private var storedWantsAutomaticUpdateChecks: Bool
    private var storedPendingSidebarSelection: String?
    private var storedSelectedTrayTabID: String?
    private var storedShowMenuBarIcon: Bool
    private var storedLaunchAtLogin: Bool
    private var storedHasCompletedOnboarding: Bool

    private static let menuBarIconKey = "showMenuBarIcon"
    private static let onboardingKey = "hasCompletedOnboarding"
    private static let trayTabKey = "selectedTrayTab"
    private static let updateChecksDisabledKey = "updates.automaticChecksDisabled"
    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    init(
        features: [Feature] = FeatureRegistry.makeAll(),
        store: FeatureStore = FeatureStore(),
        permissions: PermissionsManager = PermissionsManager(),
        updates: UpdateChecker? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.features = features
        self.store = store
        self.permissions = permissions
        self.updates = updates ?? UpdateChecker(defaults: defaults)
        self.defaults = defaults
        self.storedShowMenuBarIcon = defaults.object(forKey: Self.menuBarIconKey) as? Bool ?? true
        self.storedHasCompletedOnboarding = defaults.bool(forKey: Self.onboardingKey)
        self.storedSelectedTrayTabID = defaults.string(forKey: Self.trayTabKey)
        self.storedPendingSidebarSelection = nil
        // Registering the background item is deliberately NOT done here. Tests construct
        // AppState directly, and nothing in a test run should be planting login items on the
        // machine it runs on. AppDelegate owns that, and gates it on AppIdentity.isRunningTests.
        self.storedWantsAutomaticUpdateChecks = !defaults.bool(forKey: Self.updateChecksDisabledKey)
        // Read once at startup, exactly like `launchAtLogin` above, so no status read ever
        // happens inside a render pass. AppDelegate refreshes it after it has reconciled.
        self.storedAutomaticUpdateChecks = UpdateCheckAgent.isEnabled
        // Read once at startup. After this the value only changes when the user changes it,
        // and the setter is what talks to SMAppService.
        self.storedLaunchAtLogin = LaunchAtLogin.isEnabled

        // The permission poll does double duty: it updates the checkmark AND retries
        // activation. tapCreate fails outright while untrusted, so without this a user who
        // grants access sees nothing happen until they relaunch.
        permissions.onGrantsChanged = { [weak self] in self?.sync() }
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

        // Same reason, same caveat: UpdateChecker announces only when its answer actually
        // changes, so forwarding it cannot double-publish the way forwarding the store would.
        self.updates.objectWillChange
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

    /// The panels the switched-on features contribute to the menu bar, merged and in registry
    /// order.
    ///
    /// The two panels the app always shows — Features and General — are *not* here: they have no
    /// feature behind them and their content belongs to the view that draws them.
    /// `TrayPanel.strip(contributed:features:general:)` puts the three together, and is where the
    /// "General is always last" rule lives.
    ///
    /// Blocked features are excluded as well as disabled ones. A feature whose permission was
    /// revoked is not running, so its panel would show a frozen last reading with nothing to say
    /// why — the Features tab is where it explains itself, with the rest of the blocked list.
    @MainActor
    var contributedTrayPanels: [TrayPanel] {
        features
            .filter { feature in
                guard !blockedFeatureIDs.contains(feature.id) else { return false }
                return store.isEnabled(feature.id) || feature.panelIsItsOwnSwitch
            }
            .flatMap { $0.trayPanels() }
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
    var needsPermission: Bool {
        !unmetRequirements.isEmpty
    }

    /// The missing grants in a stable order.
    ///
    /// `unmetRequirements` is a `Set`, whose iteration order is not stable between launches — so
    /// rendering it directly would let two banners swap places at random. `sortOrder` is the
    /// declaration order of the enum.
    var unmetRequirementsInOrder: [Requirement] {
        unmetRequirements.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The missing permission that is holding one feature back, if any.
    ///
    /// Used for the row caption and the detail pane's explanation, both of which named
    /// Accessibility unconditionally before there was a second grant to get wrong.
    func blockingRequirement(for feature: Feature) -> Requirement? {
        feature.requirements
            .filter { $0.isQueryable && !permissions.isGranted($0) }
            .min { $0.sortOrder < $1.sortOrder }
    }

    /// Which permissions the enabled features are missing.
    ///
    /// Only ever contains requirements the system lets us query — see
    /// `PermissionsManager.isGranted`. A requirement we can't ask about can't be reported as
    /// missing, only noticed as not working.
    var unmetRequirements: Set<Requirement> {
        var unmet: Set<Requirement> = []
        for feature in features where store.isEnabled(feature.id) {
            for requirement in feature.requirements
            where requirement.isQueryable && !permissions.isGranted(requirement) {
                unmet.insert(requirement)
            }
        }
        return unmet
    }

    /// Which features are currently activated, so `sync()` can touch only what changed.
    private var activeFeatureIDs: Set<String> = []

    private func sync() {
        let wanted = features.filter { store.isEnabled($0.id) }
        let permitted = wanted.filter { feature in
            // A requirement we cannot query cannot gate anything — see `Requirement.isQueryable`.
            feature.requirements.allSatisfy {
                !$0.isQueryable || permissions.isGranted($0)
            }
        }

        // The tap itself is still rebuilt from scratch: there is one tap, its mask is the union
        // of its subscribers, and any change to the set means a new mask anyway.
        //
        // Only features that actually consume input events reach it. A folder-watching feature has
        // no event mask and simply activates.
        let tapFeatures = permitted.compactMap { $0 as? EventTapFeature }
        let started = tapFeatures.isEmpty || tap.setSubscribers(tapFeatures)

        // A tap that failed to start blocks the features that depend on it — but features that
        // don't need it are unaffected and should still run.
        let runnable = started ? permitted : permitted.filter { !($0 is EventTapFeature) }
        let runnableIDs = Set(runnable.map(\.id))

        // Touch only the features whose state actually changed.
        //
        // This used to deactivate *every* feature and reactivate every runnable one, on every
        // toggle. Activation is not cheap: between them the features fork `pmset`, enumerate
        // /Applications, walk the Trash and sweep every watched folder — synchronously, on the
        // thread the event tap runs on. Toggling one feature has no business restarting the other
        // seven, and the cost was paid as input latency across the whole system.
        for feature in features
        where activeFeatureIDs.contains(feature.id) && !runnableIDs.contains(feature.id) {
            feature.deactivate()
        }
        for feature in runnable where !activeFeatureIDs.contains(feature.id) {
            feature.activate()
        }
        activeFeatureIDs = runnableIDs

        let unrunnable = Set(wanted.map(\.id)).subtracting(permitted.map(\.id))
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
