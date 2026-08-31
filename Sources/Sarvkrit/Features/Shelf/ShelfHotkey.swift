import Carbon.HIToolbox
import Foundation

/// A global shortcut registered with Carbon rather than the event tap.
///
/// **This is the only global gesture in the app that doesn't go through `EventTapService`, and the
/// reason is the whole point of the Shelf: `RegisterEventHotKey` needs no Accessibility permission.**
/// An event tap does, and so does `NSEvent.addGlobalMonitorForEvents`. Since the Shelf's screen-edge
/// and menu-bar triggers are permission-free too, routing the shortcut through the tap would have
/// been the one thing forcing a permission the feature otherwise doesn't need.
///
/// The cost is a second mechanism to understand, which is why it is confined to this file and why
/// this comment exists.
final class ShelfHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onFire: (() -> Void)?

    /// ⌃⌥S. Chosen to avoid what the app already claims — ⌘⇧C and ⌃⌥1–5 belong to the clipboard,
    /// and ⌃⌥ plus letters is the window feature's family, but S is not among its bindings.
    static let defaultKeyCode = UInt32(kVK_ANSI_S)
    static let defaultModifiers = UInt32(controlKey | optionKey)

    /// Carbon identifies hot keys by a four-char code plus an id; both are ours to choose.
    private static let signature: OSType = 0x5341_5256   // "SARV"
    private static let identifier: UInt32 = 1

    func register(onFire: @escaping () -> Void) {
        unregister()
        self.onFire = onFire

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The handler is a C function pointer, so `self` travels as `userData` rather than being
        // captured — the same unretained-pointer discipline `EventTapService` documents.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }

            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr, id.id == ShelfHotkey.identifier else {
                return OSStatus(eventNotHandledErr)
            }

            let hotkey = Unmanaged<ShelfHotkey>.fromOpaque(userData).takeUnretainedValue()
            hotkey.onFire?()
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        RegisterEventHotKey(
            Self.defaultKeyCode,
            Self.defaultModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        onFire = nil
    }

    /// The handler holds `self` unretained, so a hot key left registered after its owner is gone
    /// would dereference freed memory on the next press — the same hazard `EventTapService`
    /// guards with its own `deinit`.
    deinit {
        unregister()
    }
}
