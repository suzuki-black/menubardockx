import Foundation
import Carbon

extension Notification.Name {
    static let globalShortcutTriggered = Notification.Name("MBDXGlobalShortcutTriggered")
}

/// Registers a global hotkey via the Carbon Event Manager.
/// Default: ⌥⌘M (Option + Command + M), kVK_ANSI_M = 46.
final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        installEventHandler()
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4D424458) // 'MBDX'
        hotKeyID.id = 1

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            NSLog("[GlobalShortcutManager] RegisterEventHotKey failed: \(status)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: - Carbon event handler

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                NotificationCenter.default.post(name: .globalShortcutTriggered, object: nil)
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    deinit {
        unregister()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
    }
}
