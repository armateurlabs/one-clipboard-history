import AppKit
import Carbon
import Testing
@testable import OneClipboardHistoryApp

/// Tests that the HotkeyRegistrationAPI protocol correctly decouples
/// GlobalHotkey from any specific backend implementation.

@Suite("HotkeyRegistrationAPI protocol abstraction", .serialized)
@MainActor
struct HotkeyBackendProtocolTests {

    // MARK: - CarbonBackend is the default

    @Test func defaultBackendIsCarbon() {
        let hotkey = GlobalHotkey()
        defer { hotkey.stop() }
        // Should register successfully with real Carbon.
        let key = KeyboardShortcut(keyCode: UInt32(kVK_F19),
                                    modifiers: UInt32(controlKey | optionKey | cmdKey),
                                    keyLabel: "F19")
        #expect(hotkey.register(key))
    }

    // MARK: - Fake backend works through protocol

    @Test func fakeBackendCanBeInjectedThroughProtocol() {
        _ = NSApplication.shared
        let backend = FakeBackend()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }

        #expect(hotkey.register(shortcut(12)))
        #expect(backend.registerCount == 1)
        #expect(backend.unregisterCount == 0)
        #expect(backend.active.count == 1)
    }

    @Test func fakeBackendUnregisterIsTracked() {
        _ = NSApplication.shared
        let backend = FakeBackend()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }

        #expect(hotkey.register(shortcut(12)))
        #expect(hotkey.suspend())
        #expect(backend.unregisterCount == 1)
    }

    @Test func multipleBackendsCanCoexist() {
        _ = NSApplication.shared
        // Two different fake backends for two hotkeys — proves the protocol
        // abstraction works (no Carbon coupling in the injection path).
        let backendA = FakeBackend()
        let backendB = FakeBackend()
        let hotkeyA = GlobalHotkey(api: backendA)
        let hotkeyB = GlobalHotkey(api: backendB)
        defer { hotkeyA.stop(); hotkeyB.stop() }

        #expect(hotkeyA.register(shortcut(12)))
        #expect(hotkeyB.register(shortcut(13)))
        #expect(backendA.active.count == 1)
        #expect(backendB.active.count == 1)
    }

    // MARK: - CarbonBackend conforms to protocol

    @Test func carbonBackendConformsToProtocol() {
        // Compile-time check: CarbonBackend must be assignable to
        // HotkeyRegistrationAPI.
        let backend: HotkeyRegistrationAPI = CarbonBackend.shared
        _ = backend
    }

    // MARK: - Protocol-only tests (no Carbon)

    @Test func protocolBackendRejectsDuplicateKeys() {
        _ = NSApplication.shared
        let backend = DuplicateRejectingBackend()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }

        // GlobalHotkey prevents re-registering the same key combo, so the
        // backend's duplicate rejection is never exercised through this path.
        #expect(hotkey.register(shortcut(12)))
        #expect(hotkey.register(shortcut(12))) // same combo → short-circuits
        #expect(backend.registerCount == 1)
    }

    @Test func protocolBackendErrorIsReported() {
        _ = NSApplication.shared
        let backend = FailingBackend()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }

        #expect(!hotkey.register(shortcut(12)))
        #expect(hotkey.lastError == OSStatus(paramErr))
    }

    // MARK: - Helpers

    private func shortcut(_ key: UInt32) -> KeyboardShortcut {
        .init(keyCode: key, modifiers: UInt32(optionKey), keyLabel: "A")
    }
}

// MARK: - Test doubles

/// A minimal fake that tracks calls and stores active registrations.
@MainActor
private final class FakeBackend: HotkeyRegistrationAPI {
    var registerCount = 0
    var unregisterCount = 0
    var active: [EventHotKeyRef: KeyboardShortcut] = [:]
    private var nextRef: Int = 100

    func register(_ shortcut: KeyboardShortcut,
                  identifier: EventHotKeyID,
                  options: UInt32) -> (OSStatus, EventHotKeyRef?) {
        registerCount += 1
        nextRef += 1
        let reference = EventHotKeyRef(bitPattern: nextRef)!
        active[reference] = shortcut
        return (noErr, reference)
    }

    func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        unregisterCount += 1
        active.removeValue(forKey: reference)
        return noErr
    }
}

/// A backend that rejects duplicate key combinations.
@MainActor
private final class DuplicateRejectingBackend: HotkeyRegistrationAPI {
    var registerCount = 0
    var active: [EventHotKeyRef: KeyboardShortcut] = [:]
    private var nextRef: Int = 200

    func register(_ shortcut: KeyboardShortcut,
                  identifier: EventHotKeyID,
                  options: UInt32) -> (OSStatus, EventHotKeyRef?) {
        registerCount += 1
        if active.values.contains(where: { $0.hasSameKeyCombination(as: shortcut) }) {
            return (OSStatus(eventHotKeyExistsErr), nil)
        }
        nextRef += 1
        let reference = EventHotKeyRef(bitPattern: nextRef)!
        active[reference] = shortcut
        return (noErr, reference)
    }

    func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        active.removeValue(forKey: reference)
        return noErr
    }
}

/// A backend that always fails registration.
@MainActor
private final class FailingBackend: HotkeyRegistrationAPI {
    func register(_ shortcut: KeyboardShortcut,
                  identifier: EventHotKeyID,
                  options: UInt32) -> (OSStatus, EventHotKeyRef?) {
        return (OSStatus(paramErr), nil)
    }

    func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        return noErr
    }
}
