import Foundation
import ServiceManagement
import os

/// Wrapper over the `SMAppService.agent` that runs `check-for-update.sh`.
///
/// Shaped after `LaunchAtLogin`, and for the same reason: the setter is the only place the
/// cross-process call happens, and it returns the state actually achieved rather than the state
/// that was asked for. Reading `SMAppService.status` from a getter would put an XPC round trip
/// inside the render loop, which is the bug the `launchAtLogin` comment records.
///
/// The one thing this adds over `LaunchAtLogin` is `.requiresApproval`. A user can switch the
/// background item off in System Settings, after which `register()` is a no-op — and a toggle
/// sitting ON while nothing runs is the single worst outcome for a feature whose entire job is to
/// tell you about updates. So that state is surfaced rather than collapsed into "off".
enum UpdateCheckAgent {
    static let label = "ai.psylief.sarvkrit.updatecheck"
    static let scriptName = "check-for-update.sh"

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "UpdateCheck")
    private static var service: SMAppService { .agent(plistName: label + ".plist") }

    static var status: SMAppService.Status { service.status }
    static var isEnabled: Bool { status == .enabled }

    /// The user switched it off in System Settings. `register()` won't undo that; only they can.
    static var needsApproval: Bool { status == .requiresApproval }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try service.register()
            } else if status != .notRegistered && status != .notFound {
                // Both of those mean there is nothing registered to remove, and unregistering
                // nothing just throws.
                try service.unregister()
            }
        } catch {
            log.error("failed to set the update check to \(enabled): \(error.localizedDescription, privacy: .public)")
        }
        return isEnabled
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Idempotent repair, run at every launch.
    ///
    /// `install.sh` updates by `rm -rf`ing the bundle and copying the new one over it, and the
    /// signing identity changes the day there is a paid Developer account — either can leave the
    /// registration behind. Re-registering when we find it missing costs nothing and fixes both.
    ///
    /// It deliberately does nothing when the user has opted out, and nothing when the status is
    /// `.requiresApproval`: re-registering over a deliberate refusal would be the app arguing
    /// with the user through the one switch they were given.
    static func reconcile(userWants: Bool) {
        switch (userWants, status) {
        case (true, .notRegistered), (true, .notFound):
            // `.notFound` and not just `.notRegistered`, because `.notFound` is what a bundled
            // agent that has never been registered actually reports — verified on 14.4, where a
            // fresh install returns 3 and not 0. Guarding on `.notRegistered` alone meant this
            // never fired in the one case it exists for. A genuinely missing or misnamed plist
            // reports `.notFound` too; `register()` then throws and says so, which is the only
            // way to tell those two apart from out here.
            set(true)
        case (false, .enabled):
            // The other direction matters too. The switch lives in the app, so a preference that
            // was turned off while a stale registration survived — an old bundle replaced
            // underneath us, a defaults domain restored from a backup — would otherwise leave a
            // job running that the user had already said no to.
            set(false)
        default:
            // .requiresApproval is left alone in both directions: the user refused it in System
            // Settings, and re-registering would be the app arguing back through the one switch
            // it gave them.
            break
        }
    }

    /// Whether this copy of the app should register the job automatically.
    ///
    /// A build directory is not a home. Registering one plants a background-item record pointing
    /// at a path `make clean` deletes, and the user is left with a permanent orphan row in Login
    /// Items for an app that no longer exists there. The toggle still works if someone asks for it
    /// explicitly; only the silent launch-time registration is held back.
    static func isInstalledLocation(_ url: URL = Bundle.main.bundleURL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}
