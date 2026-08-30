import Combine
import Foundation
import SwiftUI

/// Persists which features the user has switched on.
///
/// Deliberately stores *intent*, not runtime state: a feature can be "enabled" here while
/// being inactive because Accessibility hasn't been granted yet. `AppState` reconciles the
/// two, which is what lets a permission grant light everything up without a relaunch.
final class FeatureStore: ObservableObject {
    private static let key = "enabledFeatureIDs"

    private let defaults: UserDefaults
    @Published private(set) var enabledIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Self.key) as? [String] ?? []
        self.enabledIDs = Set(stored)
    }

    func isEnabled(_ id: String) -> Bool {
        enabledIDs.contains(id)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard isEnabled(id) != enabled else { return }
        if enabled {
            enabledIDs.insert(id)
        } else {
            enabledIDs.remove(id)
        }
        defaults.set(Array(enabledIDs).sorted(), forKey: Self.key)
    }
}
