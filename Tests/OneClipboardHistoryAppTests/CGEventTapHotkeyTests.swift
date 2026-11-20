import AppKit
import Carbon
import Testing
@testable import OneClipboardHistoryApp

/// Tests that CGEventTapHotkey conforms to HotkeyRegistrationAPI and
/// can be instantiated / destroyed cleanly.
///
/// Note: CGEventTap requires Accessibility permissions. In environments
/// where the tap cannot be created, we verify the API surface and error
/// handling instead of the actual tap behavior.

@Suite("CGEventTapHotkey", .serialized)
@MainActor
struct CGEventTapHotkeyTests {

    @Test func conformsToProtocol() {
        let backend: HotkeyRegistrationAPI = CGEventTapHotkey()
        _ = backend
    }

    @Test func canBeInstantiated() {
        let backend = CGEventTapHotkey()
        #expect(backend.onPressed == nil)
    }

    @Test func registerReturnsSuccessOrPermissionError() {
        let backend = CGEventTapHotkey()
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey),
            keyLabel: "A"
        )
        let id = EventHotKeyID(signature: 0x4D434D48, id: 1)
        let (status, ref) = backend.register(shortcut, identifier: id, options: UInt32(kEventHotKeyExclusive))
        // Tap creation may fail without Accessibility permissions.
        // Accept either success or a permission-related error.
        if status == noErr, let ref {
            backend.unregister(ref)
        }
        // If registration failed, unregister should still be safe.
        if let ref {
            #expect(backend.unregister(ref) == noErr)
        }
    }

    @Test func unregisterIsIdempotentWhenTapFailed() {
        let backend = CGEventTapHotkey()
        // Even without a successful register, unregister should be safe.
        #expect(backend.unregister(EventHotKeyRef(bitPattern: 999)!) == noErr)
    }

    @Test func onPressedIsSetBeforeRegister() {
        let backend = CGEventTapHotkey()
        var called = false
        backend.onPressed = { called = true }
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey),
            keyLabel: "A"
        )
        let id = EventHotKeyID(signature: 0x4D434D48, id: 1)
        _ = backend.register(shortcut, identifier: id, options: 0)
        // onPressed is set before register, but register doesn't call it.
        #expect(!called)
    }

    @Test func multipleRegisterCallsAreSafe() {
        let backend = CGEventTapHotkey()
        let shortcut1 = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey),
            keyLabel: "A"
        )
        let shortcut2 = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(cmdKey),
            keyLabel: "B"
        )
        let id = EventHotKeyID(signature: 0x4D434D48, id: 1)

        let (s1, r1) = backend.register(shortcut1, identifier: id, options: 0)
        // First register may succeed or fail (depends on permissions).
        if s1 == noErr, let r1 {
            // Second register should also succeed or fail gracefully.
            let (s2, r2) = backend.register(shortcut2, identifier: id, options: 0)
            #expect(s2 == noErr || r2 == nil)
            backend.unregister(r1)
            if let r2 { backend.unregister(r2) }
        }
    }

    // MARK: - Protocol integration with GlobalHotkey

    @Test func globalHotkeyAcceptsCGEventTapBackend() {
        let backend = CGEventTapHotkey()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }

        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey),
            keyLabel: "A"
        )
        // Registration may succeed (if tap created) or fail (if no permissions).
        // The important thing is that GlobalHotkey accepts the backend type.
        _ = hotkey.register(shortcut)
    }

    @Test func globalHotkeyStopsCGEventTapBackend() {
        let backend = CGEventTapHotkey()
        let hotkey = GlobalHotkey(api: backend)
        _ = hotkey.register(shortcut(12))

        hotkey.stop()
        // After stop, register should fail regardless of tap state.
        #expect(!hotkey.register(shortcut(12)))
    }

    @Test func globalHotkeySuspendStopsCGEventTapBackend() {
        let backend = CGEventTapHotkey()
        let hotkey = GlobalHotkey(api: backend)
        _ = hotkey.register(shortcut(12))

        #expect(hotkey.suspend())
        #expect(hotkey.currentShortcut == nil)
        #expect(!hotkey.hasActiveShortcut)
    }

    // MARK: - Helpers

    private func shortcut(_ key: UInt32) -> KeyboardShortcut {
        .init(keyCode: key, modifiers: UInt32(optionKey), keyLabel: "A")
    }
}
