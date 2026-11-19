import AppKit
import Carbon
import Testing
@testable import OneClipboardHistoryApp

/// Tests for secure-input detection (T-105).
///
/// macOS blocks all global event taps when a password field or Keychain
/// dialog has focus — this is a hardware-level anti-keylogger feature.
/// The app detects this state and informs the user instead of silently
/// failing.

@Suite("Secure input detection", .serialized)
@MainActor
struct SecureInputTests {

    // MARK: - CGEventTapHotkey.isSecureInputActive

    @Test func isSecureInputActiveReturnsBool() {
        // The method must return a Bool (compile-time check).
        let result: Bool = CGEventTapHotkey.isSecureInputActive()
        #expect(result == true || result == false)
    }

    @Test func isSecureInputActiveDoesNotCrash() {
        // Call multiple times to ensure no resource leaks or crashes.
        _ = CGEventTapHotkey.isSecureInputActive()
        _ = CGEventTapHotkey.isSecureInputActive()
        _ = CGEventTapHotkey.isSecureInputActive()
    }

    // MARK: - GlobalHotkey.onSecureInputDetected

    @Test func onSecureInputDetectedIsNilByDefault() {
        let hotkey = GlobalHotkey(api: CarbonBackend.shared)
        defer { hotkey.stop() }
        #expect(hotkey.onSecureInputDetected == nil)
    }

    @Test func onSecureInputDetectedCanBeSet() async {
        let hotkey = GlobalHotkey(api: CarbonBackend.shared)
        defer { hotkey.stop() }

        hotkey.onSecureInputDetected = { /* secure input active */ }

        hotkey.checkSecureInput()
        await Task.yield()
        // With Carbon backend, checkSecureInput() calls
        // CGEventTapHotkey.isSecureInputActive(). In a normal test
        // environment this returns false, so the callback won't fire.
        // The important thing is that checkSecureInput() doesn't crash.
    }

    @Test func checkSecureInputDoesNotCrashWhenStopped() async {
        let hotkey = GlobalHotkey(api: CarbonBackend.shared)
        hotkey.stop()

        hotkey.onSecureInputDetected = { /* secure input active */ }
        hotkey.checkSecureInput()
        await Task.yield()
    }

    // MARK: - CGEventTap backend integration

    @Test func cgEventTapBackendOnPressedChecksSecureInput() async throws {
        _ = NSApplication.shared
        let cgBackend = CGEventTapHotkey()
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey),
            keyLabel: "A"
        )
        let id = EventHotKeyID(signature: 0x4D434D48, id: 1)
        let (status, ref) = cgBackend.register(shortcut, identifier: id, options: UInt32(kEventHotKeyExclusive))

        if status == noErr, let ref {
            _ = cgBackend.unregister(ref)

            let hotkey = GlobalHotkey(api: cgBackend)
            defer { hotkey.stop() }

            var pressedCalled = false
            hotkey.onPressed = { pressedCalled = true }
            hotkey.onSecureInputDetected = { /* secure input active */ }

            // Trigger the callback directly.
            // In the test environment, CGEventTapHotkey.isSecureInputActive()
            // will return false (tap can be created), so onPressed should fire.
            cgBackend.onPressed?()
            await Task.yield()

            // The callback chain works: CGEventTapHotkey.onPressed →
            // GlobalHotkey checks secure input → onPressed or onSecureInputDetected
            // Since we're not in secure input mode, onPressed should be called.
            #expect(pressedCalled)
        }
    }

    // MARK: - Carbon backend checks

    @Test func carbonBackendCheckSecureInputDoesNotCrash() async {
        let hotkey = GlobalHotkey(api: CarbonBackend.shared)
        defer { hotkey.stop() }

        // Carbon backend doesn't set up the CGEventTap callback chain,
        // so checkSecureInput is safe to call.
        hotkey.checkSecureInput()
        await Task.yield()
    }

    // MARK: - Protocol conformance preserved

    @Test func secureInputChangesDoNotAffectProtocolConformance() {
        // CGEventTapHotkey must still conform to HotkeyRegistrationAPI.
        let backend: HotkeyRegistrationAPI = CGEventTapHotkey()
        _ = backend
    }

    @Test func globalHotkeyAcceptsCarbonBackendAfterSecureInputChanges() {
        _ = NSApplication.shared
        let hotkey = GlobalHotkey(api: CarbonBackend.shared)
        defer { hotkey.stop() }

        let key = KeyboardShortcut(
            keyCode: UInt32(kVK_F19),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            keyLabel: "F19"
        )
        #expect(hotkey.register(key))
        // CarbonBackend is passed, but selectBackend tries CGEventTap first.
        // The important thing is that the hotkey works regardless of backend.
        #expect(hotkey.hasActiveShortcut)
    }

    // MARK: - checkSecureInput with Fake backend

    @Test func checkSecureInputWithFakeBackend() async {
        let backend = TestFakeBackend()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }

        var secureInputCalled = false
        hotkey.onSecureInputDetected = { secureInputCalled = true }

        // checkSecureInput calls CGEventTapHotkey.isSecureInputActive()
        // which returns false in normal test environments.
        hotkey.checkSecureInput()
        await Task.yield()
        #expect(!secureInputCalled)
    }

    // MARK: - Helpers

    /// A minimal fake backend for testing GlobalHotkey behavior.
    private final class TestFakeBackend: HotkeyRegistrationAPI {
        var registerCount = 0
        var unregisterCount = 0
        private var nextRef: Int = 100

        func register(_ shortcut: KeyboardShortcut,
                      identifier: EventHotKeyID,
                      options: UInt32) -> (OSStatus, EventHotKeyRef?) {
            registerCount += 1
            nextRef += 1
            let reference = EventHotKeyRef(bitPattern: nextRef)!
            return (noErr, reference)
        }

        func unregister(_ reference: EventHotKeyRef) -> OSStatus {
            unregisterCount += 1
            return noErr
        }
    }
}
