import Foundation
import ServiceManagement
import os

/// Wrapper over `SMAppService.mainApp`.
///
/// The registration binds to the bundle's current path, so enabling this from a DerivedData
/// build registers *that* copy. It only behaves as users expect once the app is in
/// /Applications — the General pane says so.
enum LaunchAtLogin {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "LaunchAtLogin")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the state actually achieved, which may differ from what was asked when the
    /// user has denied login items in System Settings.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("failed to set launch at login to \(enabled): \(error.localizedDescription)")
        }
        return isEnabled
    }
}
