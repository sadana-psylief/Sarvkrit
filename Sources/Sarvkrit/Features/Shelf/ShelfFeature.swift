import AppKit
import Foundation
import SwiftUI

/// Park files, text and links mid-drag, then drop them where they belong later.
///
/// **The only feature here that needs no permission at all**, and that is worth protecting rather
/// than an accident. `requirements` on `Feature` defaults to `[.accessibility]`, so this overrides it
/// explicitly — otherwise the UI would gate the Shelf behind a grant it never uses.
///
/// Three of its four triggers are permission-free: the screen edge works because a window
/// registered for dragged types is *told* when a drag passes over it, the menu bar entry is just a
/// button, and the shortcut uses Carbon rather than the event tap. Only "follow my cursor while
/// dragging" needs Accessibility, and it is off by default and says so.
final class ShelfFeature: Feature, ObservableObject {
    let id = "shelf"
    let category = FeatureCategory.files
    let title = "Shelf"
    let summary = "Park things mid-drag, drop them later"
    let details = """
        A place to put things down. Drag files, text or links onto the shelf, go and find where they \
        actually belong, then drag them back out.

        Open it by dragging to a screen edge, with ⌃⌥S, or from the Sarvkrit menu. Files are held \
        as references, not copies — taking something off the shelf never deletes your file, and \
        Sarvkrit follows a file that gets renamed or moved while it's parked.

        This feature needs no permissions at all. It works even if you've refused Accessibility \
        access, which nothing else here can say.
        """
    let symbolName = "tray.full"
    var shortcutHint: String? { "⌃⌥S" }

    /// Deliberately empty, and load-bearing — see the type's own comment.
    let requirements: Set<Requirement> = []

    let store: ShelfStore
    private let hotkey = ShelfHotkey()
    private let defaults: UserDefaults

    /// Set by the UI layer so this type never imports it, the same separation `ClipboardFeature`
    /// keeps for its picker.
    var showShelf: (() -> Void)?
    var installEdgeStrips: ((ScreenPlacement.Edge, CGFloat) -> Void)?
    var removeEdgeStrips: (() -> Void)?

    // MARK: - Settings

    var opensFromScreenEdge: Bool {
        get { defaults.object(forKey: Self.edgeEnabledKey) as? Bool ?? true }
        set {
            guard newValue != opensFromScreenEdge else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.edgeEnabledKey)
            applyEdgeStrips()
        }
    }

    var screenEdge: ScreenPlacement.Edge {
        get {
            defaults.string(forKey: Self.edgeKey)
                .flatMap(ScreenPlacement.Edge.init(rawValue:)) ?? .right
        }
        set {
            guard newValue != screenEdge else { return }
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Self.edgeKey)
            applyEdgeStrips()
        }
    }

    /// How deep the invisible strip is. Generous enough to hit mid-drag without aiming, shallow
    /// enough that an ordinary drag across the screen doesn't brush it.
    var edgeThickness: CGFloat { 6 }

    var globalShortcutEnabled: Bool {
        get { defaults.object(forKey: Self.shortcutKey) as? Bool ?? true }
        set {
            guard newValue != globalShortcutEnabled else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.shortcutKey)
            applyHotkey()
        }
    }

    private static let edgeEnabledKey = "shelf.opensFromScreenEdge"
    private static let edgeKey = "shelf.screenEdge"
    private static let shortcutKey = "shelf.globalShortcut"

    init(store: ShelfStore = ShelfStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    // MARK: - Lifecycle

    private var isRunning = false
    private var screenObserver: NSObjectProtocol?

    func activate() {
        isRunning = true
        applyHotkey()
        applyEdgeStrips()

        // Strips are per screen, so plugging in a monitor needs new ones.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyEdgeStrips()
        }
    }

    func deactivate() {
        isRunning = false
        hotkey.unregister()
        removeEdgeStrips?()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(ShelfDetailView(feature: self, store: store))
    }

    // MARK: - Triggers

    private func applyHotkey() {
        guard isRunning, globalShortcutEnabled else {
            hotkey.unregister()
            return
        }
        hotkey.register { [weak self] in
            DispatchQueue.main.async { self?.showShelf?() }
        }
    }

    private func applyEdgeStrips() {
        guard isRunning, opensFromScreenEdge else {
            removeEdgeStrips?()
            return
        }
        installEdgeStrips?(screenEdge, edgeThickness)
    }
}
