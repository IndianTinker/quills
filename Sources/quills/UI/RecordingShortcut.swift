import Carbon
import Foundation

/// Carbon hot keys work across apps without monitoring keystrokes or requiring
/// Accessibility permission. The application event target delivers on main.
@MainActor
final class RecordingShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let hotKeyID: UInt32
    private static let signature: OSType = 0x514C4C31 // QLL1

    init?(keyCode: UInt32 = UInt32(kVK_ANSI_R), id: UInt32 = 1, action: @escaping () -> Void) {
        self.action = action
        self.hotKeyID = id
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x514C4C31 else {
                return OSStatus(eventNotHandledErr)
            }
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<RecordingShortcut>.fromOpaque(context).takeUnretainedValue()
                guard id.id == shortcut.hotKeyID else { return OSStatus(eventNotHandledErr) }
                shortcut.action()
                return noErr
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return nil }

        let registration = RegisterEventHotKey(keyCode, UInt32(cmdKey | optionKey | controlKey),
                                              EventHotKeyID(signature: Self.signature, id: id),
                                              GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registration == noErr else {
            stop()
            return nil
        }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
