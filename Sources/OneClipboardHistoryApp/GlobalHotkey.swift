import AppKit
import Carbon

@MainActor
struct HotkeyRegistrationAPI {
    var register: (KeyboardShortcut, EventHotKeyID, UInt32) -> (OSStatus, EventHotKeyRef?)
    var unregister: (EventHotKeyRef) -> OSStatus

    static let carbon = Self(register: { shortcut, identifier, options in
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), options, &reference)
        return (status, reference)
    }, unregister: { UnregisterEventHotKey($0) })
}

@MainActor
final class GlobalHotkey {
    private static var nextID: UInt32 = 0
    nonisolated let eventID: UInt32
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let api: HotkeyRegistrationAPI
    private var suspendedShortcut: KeyboardShortcut?
    private var cleanupReferences: [EventHotKeyRef] = []
    private var stopped = false
    private(set) var currentShortcut: KeyboardShortcut?
    private(set) var lastError: OSStatus?
    var hasActiveShortcut: Bool { !stopped && reference != nil && cleanupReferences.isEmpty }
    var onPressed: (() -> Void)?

    init(api: HotkeyRegistrationAPI = .carbon) {
        self.api = api
        Self.nextID &+= 1
        eventID = Self.nextID
        _ = installHandlerIfNeeded()
    }

    private func installHandlerIfNeeded() -> Bool {
        if handler != nil { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x4D434D48 else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            guard identifier.id == hotkey.eventID else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in
                guard hotkey.hasActiveShortcut else { return }
                hotkey.onPressed?()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if installed != noErr { lastError = installed }
        return installed == noErr && handler != nil
    }

    func register(_ shortcut: KeyboardShortcut, force: Bool = false) -> Bool {
        guard !stopped, installHandlerIfNeeded() else { return false }
        guard cleanUpProvisionalRegistrations() else { return false }
        if let currentShortcut, currentShortcut.hasSameKeyCombination(as: shortcut) {
            if !force {
                // A changed display label is not a new Carbon binding.
                self.currentShortcut = shortcut
                lastError = nil
                return true
            }
            if !suspend() {
                // A stale OS reference may refuse removal even though its key
                // no longer exists. Probe a fresh exclusive registration while
                // retaining the old handle if that probe also fails.
                let failure = lastError
                guard let recovered = nativeRegistration(shortcut) else {
                    lastError = failure
                    return false
                }
                reference = recovered
                self.currentShortcut = shortcut
                suspendedShortcut = nil
                return true
            }
        }
        // Register first, so a conflict cannot remove the previous working shortcut.
        guard let next = nativeRegistration(shortcut) else {
            let failure = lastError
            // Recording temporarily releases the old key so the recorder can
            // receive it. If a replacement conflicts, restore the old binding.
            if reference == nil, let previous = suspendedShortcut,
               let restored = nativeRegistration(previous) {
                reference = restored
                currentShortcut = previous
                if previous.hasSameKeyCombination(as: shortcut) {
                    suspendedShortcut = nil
                    return true
                }
            }
            suspendedShortcut = nil
            lastError = failure
            return false
        }
        if let reference {
            let status = api.unregister(reference)
            if status != noErr {
                // Keep the previous handle if replacement cannot be completed.
                // Never forget a provisional handle, even if rollback also fails.
                if api.unregister(next) != noErr { cleanupReferences.append(next) }
                lastError = status
                return false
            }
        }
        reference = next
        currentShortcut = shortcut
        suspendedShortcut = nil
        return true
    }

    private func nativeRegistration(_ shortcut: KeyboardShortcut) -> EventHotKeyRef? {
        // Nonexclusive Carbon registrations can report success while another
        // app's exclusive registration suppresses all of our notifications.
        let (status, next) = api.register(shortcut,
            EventHotKeyID(signature: 0x4D434D48, id: eventID), UInt32(kEventHotKeyExclusive))
        guard status == noErr, let next else {
            lastError = status == noErr ? OSStatus(eventNotHandledErr) : status
            return nil
        }
        lastError = nil
        return next
    }

    func stop() {
        suspend()
        suspendedShortcut = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        stopped = true
    }

    @discardableResult
    func suspend() -> Bool {
        guard cleanUpProvisionalRegistrations() else { return false }
        if let reference {
            let status = api.unregister(reference)
            guard status == noErr else {
                lastError = status
                return false
            }
        }
        if let currentShortcut { suspendedShortcut = currentShortcut }
        reference = nil
        currentShortcut = nil
        return true
    }

    private func cleanUpProvisionalRegistrations() -> Bool {
        cleanupReferences = cleanupReferences.filter { reference in
            let status = api.unregister(reference)
            if status != noErr { lastError = status }
            return status != noErr
        }
        // Suppress dispatch until an uncertain replacement is fully unwound.
        return cleanupReferences.isEmpty
    }
}
