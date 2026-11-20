import AppKit
import Carbon
@preconcurrency import CoreGraphics
@preconcurrency import CoreFoundation

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
    ///
    /// Uses only the session dictionary check — no probe tap — to avoid
    /// false positives when the process lacks Accessibility permission.
    static func isSecureInputActive() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as NSDictionary?,
              dict.count > 0 else { return true }
        return false
    }

    // MARK: - Public API

    /// Callback invoked when the registered shortcut is detected.
    var onPressed: (() -> Void)?

    // MARK: - HotkeyRegistrationAPI conformance

    /// Starts the event tap (or updates the shortcut if already active).
    /// Returns a reference token.
    func register(_ shortcut: KeyboardShortcut,
                  identifier: EventHotKeyID,
                  options: UInt32) -> (OSStatus, EventHotKeyRef?) {
        // If a tap is already active, update the shortcut and return success.
        // This fixes the register-replacement contract: replacing a different
        // combo must actually switch the active shortcut, not no-op.
        if tap != nil {
            self.shortcut = shortcut
            return (noErr, EventHotKeyRef(bitPattern: 1)!)
        }

        self.shortcut = shortcut

        // Create the tap: listen for keyboard events in the session.
        // Include tapDisabledByTimeout and tapDisabledByUserInput so we can
        // re-enable the tap if macOS auto-disables it.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

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

        CGEvent.tapEnable(tap: tap, enable: true)

        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
            return (OSStatus(paramErr), nil)
        }
        CFRunLoopAddSource(RunLoop.main.getCFRunLoop(), source, .commonModes)
        self.runLoopSource = source

        return (noErr, EventHotKeyRef(bitPattern: 1)!)
    }

    /// Stops the event tap and releases all resources.
    func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        teardown()
        shortcut = nil
        return noErr
    }

    // MARK: - Teardown

    /// Disables the tap, removes the run loop source, and clears references.
    /// Safe to call multiple times. Core Foundation objects are ARC-managed
    /// in Swift, so setting properties to nil releases them automatically.
    private func teardown() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(RunLoop.main.getCFRunLoop(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    // MARK: - Event processing

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcut: KeyboardShortcut?
    private var currentFlags: NSEvent.ModifierFlags = []

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let selfPtr = Unmanaged<CGEventTapHotkey>.fromOpaque(refcon)
        let strongSelf = selfPtr.takeUnretainedValue()

        // The run loop source is attached to RunLoop.main, so the callback
        // is guaranteed to run on the main thread. Use assumeIsolated to
        // satisfy Swift 6 actor isolation.
        let result: Unmanaged<CGEvent>? = MainActor.assumeIsolated {
            // Re-enable if macOS auto-disabled the tap.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = strongSelf.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            // Check if this keyDown matches the registered shortcut.
            if type == .keyDown,
               let shortcut = strongSelf.shortcut,
               event.getIntegerValueField(.keyboardEventKeycode) == Int64(shortcut.keyCode),
               strongSelf.eventModifiersMatch(shortcut.modifiers) {
                // Drop the event entirely so the focused app receives no
                // key press at all. Returning nil from a CGEventTap
                // callback swallows the event; remapping the key code
                // instead would deliver a stray (and usually unhandled)
                // combination to the focused app, which plays the system
                // alert sound. Fire the handler only on the initial
                // press, not on auto-repeat.
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    strongSelf.onPressed?()
                }
                return nil
            }

            // Ignore key auto-repeat.
            if type == .keyDown,
               event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return Unmanaged.passUnretained(event)
            }

            // Update tracked modifier state for flagsChanged.
            if type == .flagsChanged {
                let flags = event.flags
                var newFlags: NSEvent.ModifierFlags = []
                if flags.contains(.maskCommand)   { newFlags.insert(.command) }
                if flags.contains(.maskAlternate) { newFlags.insert(.option) }
                if flags.contains(.maskControl)   { newFlags.insert(.control) }
                if flags.contains(.maskShift)     { newFlags.insert(.shift) }
                strongSelf.currentFlags = newFlags
            }

            return Unmanaged.passUnretained(event)
        }

        return result
    }

    /// Compare tracked NSEvent.ModifierFlags with Carbon modifier constants.
    /// Exposed as internal for unit testing.
    internal func eventModifiersMatch(_ carbonModifiers: UInt32) -> Bool {
        let expectedFlags: NSEvent.ModifierFlags = {
            var f: NSEvent.ModifierFlags = []
            if (carbonModifiers & UInt32(cmdKey)) != 0    { f.insert(.command) }
            if (carbonModifiers & UInt32(optionKey)) != 0 { f.insert(.option) }
            if (carbonModifiers & UInt32(controlKey)) != 0 { f.insert(.control) }
            if (carbonModifiers & UInt32(shiftKey)) != 0  { f.insert(.shift) }
            return f
        }()
        return currentFlags == expectedFlags
    }

    /// Exposed as internal for unit testing.
    internal var currentFlagsForTesting: NSEvent.ModifierFlags {
        get { currentFlags }
        set { currentFlags = newValue }
    }
}
