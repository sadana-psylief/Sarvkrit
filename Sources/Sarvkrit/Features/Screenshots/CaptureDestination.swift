import CoreGraphics
import Foundation

/// Where a finished capture goes.
///
/// Pure routing, separated from the doing so the policy is a test table rather than something you
/// verify by taking screenshots and looking in folders. It is also the seam a future cloud upload
/// would slot into: this is the one place that decides what happens to a finished image.
enum CaptureDestination {

    /// What the user has asked for.
    struct Settings: Equatable {
        var savesToDisk = true
        var copiesToClipboard = false
        var showsQuickAccess = true
        var opensEditor = false
    }

    /// What to actually do with one capture.
    struct Plan: Equatable {
        var writesFile = false
        var writesClipboard = false
        var showsOverlay = false
        var opensEditor = false

        /// Nothing at all would mean the shortcut appears broken.
        var isEmpty: Bool { !writesFile && !writesClipboard && !showsOverlay && !opensEditor }
    }

    /// - Parameter mode: text recognition never produces an image the user wants filed — the
    ///   point of it is the text — so it routes to the pasteboard alone regardless of settings.
    static func plan(for mode: CaptureMode, settings: Settings) -> Plan {
        if mode == .textRecognition {
            return Plan(writesFile: false, writesClipboard: true,
                        showsOverlay: false, opensEditor: false)
        }

        var plan = Plan(
            writesFile: settings.savesToDisk,
            writesClipboard: settings.copiesToClipboard,
            showsOverlay: settings.showsQuickAccess,
            opensEditor: settings.opensEditor
        )

        // A capture that goes nowhere looks like a broken shortcut, so the last resort is the
        // clipboard: it needs no folder, no permission and no window, and it is the one
        // destination that can't itself be unavailable.
        if plan.isEmpty { plan.writesClipboard = true }

        // The overlay needs a file to point at and to drag out of — `ShelfDragSource` records that
        // Finder wants a `public.file-url` and that an in-memory image "quietly did nothing". So
        // the PNG is written before the overlay appears, not when Save is clicked.
        if plan.showsOverlay || plan.opensEditor { plan.writesFile = true }

        return plan
    }
}
