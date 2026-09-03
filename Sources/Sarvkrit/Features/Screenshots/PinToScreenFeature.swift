import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI
import os

/// Keeping a screenshot on top of everything else.
///
/// **Declares no requirements at all, deliberately.** Floating an image you already have needs no
/// permission — only *making* one does, and that is `ScreenshotFeature`'s problem. `ShelfFeature`
/// makes the same point in its own comment: a feature that needs nothing is worth protecting
/// rather than letting drift into asking for something.
///
/// Note it must say so explicitly, because `Feature`'s default is `[.accessibility]`.
final class PinToScreenFeature: Feature, ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")

    let id = "pin-to-screen"
    let category = FeatureCategory.capture
    let title = "Pin to Screen"
    let summary = "Float a screenshot above other windows"
    let details = """
        Keep a screenshot on top of everything else while you work — a reference you can look at \
        without switching windows. Resize it, fade it, and drag it wherever you need it.

        Lock Mode makes a pinned shot ignore clicks so you can work through it. ⌃⇧P unlocks \
        every pinned shot, and ⌃⇧⎋ clears everything Sarvkrit has put on your screen — overlays, \
        pins and all — from anywhere, whatever state it is in.
        """
    let symbolName = "pin"
    var shortcutHint: String? { "⌃⇧P" }

    let requirements: Set<Requirement> = []

    private var hotkey: GlobalHotkey?

    func activate() {
        let hotkey = GlobalHotkey(id: GlobalHotkey.ID.pinClipboardImage)
        let status = hotkey.register(keyCode: UInt32(kVK_ANSI_P),
                                     modifiers: UInt32(controlKey | shiftKey)) { [weak self] in
            MainActor.assumeIsolated { self?.pinFromClipboardOrUnlock?() }
        }
        if status != noErr {
            log.error("couldn't register the pin hotkey: \(status, privacy: .public)")
        }
        self.hotkey = hotkey
    }

    func deactivate() {
        hotkey?.unregister()
        hotkey = nil
        MainActor.assumeIsolated { PinnedShotController.shared.closeAll() }
    }

    /// ⌃⇧P does double duty: unlock everything if anything is locked, otherwise pin whatever
    /// image is on the clipboard. Unlocking has to come first — a locked pin takes no clicks, so
    /// the shortcut is the only way out, and it must not be shadowed by the pinning behaviour.
    var pinFromClipboardOrUnlock: (() -> Void)?

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(PinToScreenDetailView(feature: self))
    }
}

struct PinToScreenDetailView: View {
    @ObservedObject var feature: PinToScreenFeature
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Pin to Screen", isOn: app.binding(for: feature))
            } footer: {
                Text("""
                    Pin a capture from the overlay that appears after a screenshot, or press ⌃⇧P \
                    to pin an image from the clipboard.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Unlock All Pinned Shots") {
                    PinnedShotController.shared.unlockAll()
                }
                Button("Close All Pinned Shots", role: .destructive) {
                    PinnedShotController.shared.closeAll()
                }
            } header: {
                Text("Lock Mode")
            } footer: {
                Text("""
                    A locked shot ignores clicks so you can work through it — which also means it \
                    can't be clicked to unlock. ⌃⇧P and the button above are the ways back, a \
                    locked shot draws a coloured border so you can tell, and ⌃⇧⎋ clears \
                    everything Sarvkrit has on screen no matter what state it is in.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("""
                    This needs no permissions at all. Floating an image you already have asks \
                    nothing of the system; only taking the screenshot does.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Requirements")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(feature.title)
    }
}
