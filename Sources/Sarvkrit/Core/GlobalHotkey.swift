import Carbon.HIToolbox
import Foundation

/// A global shortcut registered with Carbon rather than the event tap.
///
/// **The only global gesture mechanism in the app that doesn't go through `EventTapService`, and
/// the reason is permissions: `RegisterEventHotKey` needs none.** An event tap requires
/// Accessibility, and so does `NSEvent.addGlobalMonitorForEvents` for key events. Features whose
/// other triggers are permission-free — the Shelf, the audio switcher — would otherwise be forced
/// to demand a permission they never actually use.
///
/// The cost is a second mechanism to understand, which is why it lives in one file with this
/// comment on it.
///
/// **Each instance must be given a distinct `id`.** Carbon identifies hot keys by a signature and
/// an id, so two hotkeys sharing one would collide and only one would ever fire.
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onFire: (() -> Void)?

    /// ⌃⌥ plus a letter. Chosen to avoid what the app already claims — ⌘⇧C and ⌃⌥1–5 belong to the
    /// clipboard, and ⌃⌥ plus letters is the window feature's family, so each caller picks a letter
    /// that family doesn't bind.
    static let defaultModifiers = UInt32(controlKey | optionKey)

    /// Carbon identifies hot keys by a four-char code plus an id; both are ours to choose.
    private static let signature: OSType = 0x5341_5256   // "SARV"

    /// Every hot key id in the app, in one place so a duplicate is obvious rather than a silent
    /// collision where one shortcut stops working for no visible reason.
    enum ID {
        static let shelf: UInt32 = 1
        static let audioCycle: UInt32 = 2
        static let micMute: UInt32 = 3
        static let captureArea: UInt32 = 4
        static let captureWindow: UInt32 = 5
        static let captureFullscreen: UInt32 = 6
        static let captureAllInOne: UInt32 = 7
        static let captureScrolling: UInt32 = 8
        static let captureText: UInt32 = 9
        static let restoreLastOverlay: UInt32 = 10
        static let hideOverlays: UInt32 = 11
        static let pinClipboardImage: UInt32 = 12
    }

    /// Distinct per hotkey. Two sharing an id would collide.
    private let identifier: UInt32

    /// - Parameter id: unique across every `GlobalHotkey` alive at once.
    init(id: UInt32) {
        self.identifier = id
    }

    /// - Returns: `RegisterEventHotKey`'s status. **Worth checking**, because the interesting
    ///   failure is silent: the system screenshot service owns ⌘⇧3/4/5 at a lower level than this
    ///   API, so registering one of those either reports `eventHotKeyExistsErr` or succeeds and
    ///   never fires. Settings reports the failure rather than offering a shortcut that does
    ///   nothing.
    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32 = GlobalHotkey.defaultModifiers,
        onFire: @escaping () -> Void
    ) -> OSStatus {
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
            guard status == noErr else { return OSStatus(eventNotHandledErr) }

            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Each instance installs its own handler, so it must ignore presses belonging to
            // another hotkey's id or both would fire on either key.
            guard id.id == hotkey.identifier else { return OSStatus(eventNotHandledErr) }
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

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        return RegisterEventHotKey(
            keyCode,
            modifiers,
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
