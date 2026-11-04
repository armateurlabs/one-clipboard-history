import AppKit
import Carbon

@MainActor
final class GlobalHotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPressed: (() -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x4D434D48 else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in hotkey.onPressed?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: KeyboardShortcut) -> Bool {
        // Register first, so a conflict cannot remove the previous working shortcut.
        var next: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: 0x4D434D48, id: 1),
                                        GetApplicationEventTarget(), 0, &next)
        guard status == noErr else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = next
        return true
    }

    func stop() {
        suspend()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func suspend() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }
}
