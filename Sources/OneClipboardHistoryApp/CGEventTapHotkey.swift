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

    /// Returns true when some process (a password field, a stuck
    /// loginwindow, a terminal with Secure Keyboard Entry...) holds macOS
    /// secure event input. In this state the system hides keystrokes from
    /// global event taps, so the shortcut cannot fire.
    static func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// The process macOS reports as holding secure input, when any.
    ///
    /// `name` is nil for `loginwindow` (a catch-all: some startup agent or
    /// daemon is asking for a password) and for processes without a
    /// user-visible name. The attribution can be wrong: if a background
    /// process enables secure input the system may blame the foreground app.
    static func secureInputHolder() -> (pid: pid_t, name: String?)? {
        guard IsSecureEventInputEnabled(),
              let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let number = dict["kCGSSessionSecureInputPID"] as? NSNumber else { return nil }
        let pid = pid_t(truncating: number)
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.bundleIdentifier == "com.apple.loginwindow" ? nil : app?.localizedName
        return (pid, name)
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
               strongSelf.eventModifiersMatch(shortcut.modifiers, eventFlags: event.flags) {
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

            return Unmanaged.passUnretained(event)
        }

        return result
    }

    /// Compare the modifiers carried by the key event itself with Carbon
    /// modifier constants. Reading them from the event (instead of tracking
    /// flagsChanged) means a missed event while the tap was disabled can
    /// never leave stale state behind. Caps Lock, fn and numeric-pad bits
    /// are ignored.
    /// Exposed as internal for unit testing.
    internal func eventModifiersMatch(_ carbonModifiers: UInt32,
                                      eventFlags: CGEventFlags) -> Bool {
        var expected: CGEventFlags = []
        if (carbonModifiers & UInt32(cmdKey)) != 0     { expected.insert(.maskCommand) }
        if (carbonModifiers & UInt32(optionKey)) != 0  { expected.insert(.maskAlternate) }
        if (carbonModifiers & UInt32(controlKey)) != 0 { expected.insert(.maskControl) }
        if (carbonModifiers & UInt32(shiftKey)) != 0   { expected.insert(.maskShift) }
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return eventFlags.intersection(relevant) == expected
    }
}
