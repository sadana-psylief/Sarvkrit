import AppKit
import Foundation
import UserNotifications
import os

/// Whether macOS will show our notifications. A reduced copy of `UNAuthorizationStatus`, which has
/// cases (`.ephemeral`) that only exist on iOS and would be noise in every switch here.
enum NotificationPermission: Equatable {
    case notDetermined
    case allowed
    case denied
}

/// One action button on a notification.
struct NotificationAction: Equatable {
    let id: String
    let title: String
}

/// The part of `UNUserNotificationCenter` a feature uses, so tests can stand in for it.
///
/// **The first use of system notifications in the app.** Everything before this used the HUD in
/// `ToastPresenter`, which is click-through by design and so can't carry buttons. A reminder whose
/// whole job is "did you drink?" needs a Drank button, and system notifications bring two things a
/// home-made panel can't: Focus and Do Not Disturb hold them back automatically, and they land in
/// Notification Center rather than vanishing if you weren't looking.
protocol NotificationPosting: AnyObject {
    func permission(_ completion: @escaping (NotificationPermission) -> Void)
    func requestPermission(_ completion: @escaping (NotificationPermission) -> Void)
    /// Registers (or replaces) the buttons for one category. Several features may each own one.
    func register(category: String, actions: [NotificationAction])
    func post(id: String, category: String, title: String, body: String)
    func remove(ids: [String])
    /// Routes a tapped button back to whoever owns the category. Replaces any earlier handler.
    func onAction(category: String, _ handler: @escaping (_ actionID: String) -> Void)
}

/// The real thing.
///
/// Also the center's delegate, which is why it's a singleton: the delegate must be set before
/// launch finishes, or a button tapped on a notification from a previous run arrives with nobody
/// listening. `AppDelegate` touches `shared` in `applicationWillFinishLaunching` for exactly that.
final class SystemNotifications: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifications()

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Notifications")
    private var categories: [String: [NotificationAction]] = [:]
    private var handlers: [String: (String) -> Void] = [:]

    private var center: UNUserNotificationCenter { .current() }

    /// Becomes the delegate. Idempotent.
    func install() {
        center.delegate = self
    }

    func permission(_ completion: @escaping (NotificationPermission) -> Void) {
        center.getNotificationSettings { settings in
            let permission = Self.map(settings.authorizationStatus)
            DispatchQueue.main.async { completion(permission) }
        }
    }

    func requestPermission(_ completion: @escaping (NotificationPermission) -> Void) {
        // Alert and badge only. Sound is deliberately not asked for: a reminder to drink water has
        // no business making a noise in someone's headphones mid-call.
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            if let error {
                self?.log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async { completion(granted ? .allowed : .denied) }
        }
    }

    func register(category: String, actions: [NotificationAction]) {
        categories[category] = actions
        // `setNotificationCategories` replaces the whole set, so every owner's category is sent
        // each time rather than just the one that changed.
        let all = categories.map { id, actions in
            UNNotificationCategory(
                identifier: id,
                actions: actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) },
                intentIdentifiers: [],
                options: [])
        }
        center.setNotificationCategories(Set(all))
    }

    func post(id: String, category: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = nil
        // Passive: shown, but never breaks through Focus. Nothing about water is time-sensitive.
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error {
                self?.log.error("couldn't post a notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func remove(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func onAction(category: String, _ handler: @escaping (String) -> Void) {
        handlers[category] = handler
    }

    /// Opens the Notifications pane, for a user who said no and has changed their mind.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even while Sarvkrit is the active app. It's a menu bar app, so "active" usually means
    /// its panel happens to be open — which is no reason to swallow the banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            self?.handlers[category]?(action)
            completionHandler()
        }
    }
}
