import AppKit
import Carbon
import CoreGraphics

/// A HotkeyRegistrationAPI backend that uses CGEventTap to intercept
/// keyboard events at the session level.  Unlike Carbon EventHotKey,
/// this works in most text-field contexts (but not in secure-input
/// contexts — password fields, Keychain dialogs — where macOS blocks
/// all global keyboard observation by design).
@MainActor
final class CGEventTapHotkey: HotkeyRegistrationAPI {

    // MARK: - Secure input detection

    /// Returns true when macOS is in secure-input mode (e.g. a password
    /// field or Keychain dialog has focus).  In this state the kernel
    /// blocks all global event taps, so the hotkey cannot fire.
    static func isSecureInputActive() -> Bool {
        // CGSessionCopyCurrentDictionary returns nil or an empty dictionary
        // when the session is in secure-input mode.
        guard let dict = CGSessionCopyCurrentDictionary() as NSDictionary?,
              dict.count > 0 else { return true }

        // A secondary behavioural check: try to create a session tap.
        // If it fails while the dictionary exists, secure input is active.
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, _, _ in
                let event = CGEvent(source: nil)!
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )
        return tap == nil
    }

    // MARK: - Public API

    /// Callback invoked when the registered shortcut is detected.
    var onPressed: (() -> Void)?

    // MARK: - HotkeyRegistrationAPI conformance

    /// Starts the event tap.  Returns a reference token.
    func register(_ shortcut: KeyboardShortcut,
                  identifier: EventHotKeyID,
                  options: UInt32) -> (OSStatus, EventHotKeyRef?) {
        guard tap == nil else { return (noErr, EventHotKeyRef(bitPattern: 1)!) }

        self.shortcut = shortcut

        // Create the tap: listen for keyboard events in the session.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // Pass self as userInfo so the static callback can weakly reference it.
        let unmanagedSelf = Unmanaged.passUnretained(self)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: unmanagedSelf.toOpaque()
        )

        guard let tap else { return (OSStatus(paramErr), nil) }

        // Enable the tap using the new API.
        CGEvent.tapEnable(tap: tap, enable: true)

        // Attach the tap's run loop source to the main run loop.
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
            return (OSStatus(paramErr), nil)
        }
        CFRunLoopAddSource(RunLoop.main.getCFRunLoop(), source, .commonModes)
        self.runLoopSource = source

        return (noErr, EventHotKeyRef(bitPattern: 1)!)
    }

    /// Stops the event tap.
    func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        guard let tap else { return noErr }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(RunLoop.main.getCFRunLoop(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        self.tap = nil
        shortcut = nil
        return noErr
    }

    // MARK: - Event processing

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcut: KeyboardShortcut?
    private var currentFlags: NSEvent.ModifierFlags = []

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let selfPtr = Unmanaged<CGEventTapHotkey>.fromOpaque(refcon)
        // We can't use [weak self] in a C callback, so we take a strong
        // reference temporarily. The tap will be nil'd on unregister,
        // making subsequent calls no-ops.
        let strongSelf = selfPtr.takeUnretainedValue()
        strongSelf.handleEvent(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        // Only care about keyDown and flagsChanged.
        guard type == .keyDown || type == .flagsChanged else { return }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Update tracked modifier state.
        var newFlags: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand)   { newFlags.insert(.command) }
        if flags.contains(.maskAlternate) { newFlags.insert(.option) }
        if flags.contains(.maskControl)   { newFlags.insert(.control) }
        if flags.contains(.maskShift)     { newFlags.insert(.shift) }
        currentFlags = newFlags

        // Check if this keyDown matches the registered shortcut.
        if type == .keyDown,
           let shortcut,
           keyCode == shortcut.keyCode,
           eventModifiersMatch(shortcut.modifiers) {
            Task { @MainActor [weak self] in
                self?.onPressed?()
            }
        }
    }

    /// Compare tracked NSEvent.ModifierFlags with Carbon modifier constants.
    private func eventModifiersMatch(_ carbonModifiers: UInt32) -> Bool {
        var match = true
        if (carbonModifiers & UInt32(cmdKey)) != 0    { match = match && currentFlags.contains(.command) }
        if (carbonModifiers & UInt32(optionKey)) != 0 { match = match && currentFlags.contains(.option) }
        if (carbonModifiers & UInt32(controlKey)) != 0 { match = match && currentFlags.contains(.control) }
        if (carbonModifiers & UInt32(shiftKey)) != 0  { match = match && currentFlags.contains(.shift) }
        // No extra modifiers allowed beyond what the shortcut specifies.
        let expectedFlags: NSEvent.ModifierFlags = {
            var f: NSEvent.ModifierFlags = []
            if (carbonModifiers & UInt32(cmdKey)) != 0    { f.insert(.command) }
            if (carbonModifiers & UInt32(optionKey)) != 0 { f.insert(.option) }
            if (carbonModifiers & UInt32(controlKey)) != 0 { f.insert(.control) }
            if (carbonModifiers & UInt32(shiftKey)) != 0  { f.insert(.shift) }
            return f
        }()
        return match && currentFlags == expectedFlags
    }
}
