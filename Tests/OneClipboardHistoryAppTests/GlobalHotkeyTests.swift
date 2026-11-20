import AppKit
import Carbon
import Testing
@testable import OneClipboardHistoryApp

@Suite("Native hotkey dispatch", .serialized)
@MainActor
struct GlobalHotkeyTests {
    @Test func registeredHandlerRoutesOnlyOurSignature() async throws {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }
        #expect(hotkey.register(shortcut(12)))
        var count = 0
        hotkey.onPressed = { count += 1 }
        try sendHotkeyEvent(signature: 0x4D434D48, id: hotkey.eventID)
        for _ in 0..<50 where count == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(count == 1)
        try sendHotkeyEvent(signature: 0x554E4B4E, id: hotkey.eventID, requireHandled: false)
        try sendHotkeyEvent(signature: 0x4D434D48, id: hotkey.eventID + 100, requireHandled: false)
        await Task.yield()
        #expect(count == 1)
    }

    @Test func stoppingRemovesTheCarbonHandler() async throws {
        _ = NSApplication.shared
        let hotkey = GlobalHotkey(api: FakeRegistrations())
        #expect(hotkey.register(shortcut(12)))
        var called = false
        hotkey.onPressed = { called = true }
        hotkey.stop()
        try sendHotkeyEvent(signature: 0x4D434D48, id: hotkey.eventID, requireHandled: false)
        await Task.yield()
        #expect(!called)
        #expect(!hotkey.register(shortcut(12)))
    }

    @Test func exclusiveOwnerIsReportedInsteadOfSilentRegistration() {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        backend.unavailable.insert(12)
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }
        #expect(!hotkey.register(shortcut(12)))
        #expect(hotkey.currentShortcut == nil)
        #expect(hotkey.lastError == OSStatus(eventHotKeyExistsErr))
        #expect(backend.requests.first?.options == UInt32(kEventHotKeyExclusive))
    }

    @Test func labelOnlyUpdatesDoNotRegisterTheSamePhysicalKeyTwice() {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }
        #expect(hotkey.register(shortcut(12)))
        var relabeled = shortcut(12)
        relabeled.keyLabel = "Q"
        #expect(hotkey.register(relabeled))
        #expect(hotkey.currentShortcut == relabeled)
        #expect(backend.requests.count == 1)
        #expect(backend.active.count == 1)
    }

    @Test func failedReplacementRetainsOrRestoresThePreviousWorkingKey() {
        _ = NSApplication.shared
        for recording in [false, true] {
            let backend = FakeRegistrations()
            let hotkey = GlobalHotkey(api: backend)
            #expect(hotkey.register(shortcut(12)))
            if recording { hotkey.suspend() }
            backend.unavailable.insert(13)
            #expect(!hotkey.register(shortcut(13)))
            #expect(hotkey.currentShortcut == shortcut(12))
            #expect(backend.active.values.map(\.keyCode) == [12])
            hotkey.stop()
        }
    }

    @Test func failedRollbackHonestlyHasNoActiveKeyAndCanRetry() {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }
        #expect(hotkey.register(shortcut(12)))
        hotkey.suspend()
        backend.unavailable.formUnion([12, 13])
        #expect(!hotkey.register(shortcut(13)))
        #expect(hotkey.currentShortcut == nil)
        backend.unavailable.remove(13)
        #expect(hotkey.register(shortcut(13)))
        #expect(hotkey.currentShortcut == shortcut(13))
    }

    @Test func forcedRecoveryReacquiresTheNativeRegistration() {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }
        #expect(hotkey.register(shortcut(12)))
        #expect(hotkey.register(shortcut(12), force: true))
        #expect(backend.requests.count == 2)
        #expect(backend.active.count == 1)
    }

    @Test func transientRecoveryFailureGetsOneBoundedRestorationAttempt() {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }
        #expect(hotkey.register(shortcut(12)))
        backend.failNextRegistration = true
        #expect(hotkey.register(shortcut(12), force: true))
        #expect(hotkey.currentShortcut == shortcut(12))
        #expect(backend.requests.count == 3)
        #expect(backend.active.count == 1)
    }

    @Test func refusedUnregisterRetainsTheNativeHandleForALaterRetry() {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }
        #expect(hotkey.register(shortcut(12)))
        backend.refuseUnregister = true
        #expect(!hotkey.suspend())
        #expect(hotkey.currentShortcut == shortcut(12))
        #expect(!hotkey.register(shortcut(12), force: true))
        #expect(backend.active.count == 1)
        backend.refuseUnregister = false
        #expect(hotkey.register(shortcut(12), force: true))
        #expect(backend.active.count == 1)
    }

    @Test func refusedRemovalNeverForgetsAProvisionalReplacementHandle() {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        let hotkey = GlobalHotkey(api: backend)
        #expect(hotkey.register(shortcut(12)))
        backend.refuseUnregister = true
        #expect(!hotkey.register(shortcut(13)))
        #expect(hotkey.currentShortcut == shortcut(12))
        #expect(!hotkey.hasActiveShortcut)
        #expect(backend.active.count == 2)
        backend.refuseUnregister = false
        #expect(hotkey.register(shortcut(12), force: true))
        #expect(hotkey.hasActiveShortcut)
        #expect(backend.active.count == 1)
        hotkey.stop()
        #expect(backend.active.isEmpty)
    }

    @Test func staleNativeReferenceCanBeReacquiredWhenUnregisterRefusesIt() {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }
        #expect(hotkey.register(shortcut(12)))
        backend.active.removeAll() // The OS no longer owns the cached reference.
        backend.refuseUnregister = true
        #expect(hotkey.register(shortcut(12), force: true))
        #expect(hotkey.currentShortcut == shortcut(12))
        #expect(backend.active.count == 1)
        backend.refuseUnregister = false
    }

    @Test func carbonBackendDetectsConflictsAndTransfersOwnership() {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        let first = GlobalHotkey(api: backend)
        let second = GlobalHotkey(api: backend)
        defer { first.stop(); second.stop() }
        let key = KeyboardShortcut(keyCode: UInt32(kVK_F19),
            modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F19")
        #expect(first.register(key))
        #expect(!second.register(key))
        first.suspend()
        #expect(second.register(key))
    }

    // MARK: - Backend type

    @Test func backendTypeIsCGEventTapWhenTapAvailable() {
        _ = NSApplication.shared
        let hotkey = GlobalHotkey()
        defer { hotkey.stop() }
        #expect(hotkey.backendType == .cgEventTap)
    }

    @Test func customBackendIsUsedDirectly() {
        _ = NSApplication.shared
        let backend = FakeRegistrations()
        let hotkey = GlobalHotkey(api: backend)
        defer { hotkey.stop() }
        #expect(hotkey.backendType == .carbon)
        #expect(hotkey.register(shortcut(12)))
        #expect(backend.requests.count == 1)
    }

    @Test func cgEventTapBackendOnPressedIsConnected() async throws {
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
            #expect(hotkey.register(shortcut))
            var called = false
            hotkey.onPressed = { called = true }
            // CGEventTapHotkey's onPressed is connected to GlobalHotkey's onPressed.
            // Triggering it directly verifies the connection.
            cgBackend.onPressed?()
            await Task.yield()
            #expect(called)
        }
    }

    // MARK: - Backend fallback

    @Test func fallbackToCarbonBackendWhenCGEventTapRegistrationFails() async throws {
        _ = NSApplication.shared
        let cgBackend = CGEventTapHotkey()
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey),
            keyLabel: "A"
        )
        let id = EventHotKeyID(signature: 0x4D434D48, id: 0)
        let (status, ref) = cgBackend.register(shortcut, identifier: id, options: UInt32(kEventHotKeyExclusive))

        if status == noErr, let ref {
            _ = cgBackend.unregister(ref)
            // CGEventTap succeeded — verify the default path uses CGEventTap.
            let hotkey = GlobalHotkey()
            defer { hotkey.stop() }
            #expect(hotkey.backendType == .cgEventTap)
        } else {
            // CGEventTap failed — GlobalHotkey should use CarbonBackend.
            let hotkey = GlobalHotkey()
            defer { hotkey.stop() }
            #expect(hotkey.backendType == .carbon)
        }
    }

    @Test func backendTypeReflectsActiveBackend() async throws {
        _ = NSApplication.shared
        let cgBackend = CGEventTapHotkey()
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey),
            keyLabel: "A"
        )
        let id = EventHotKeyID(signature: 0x4D434D48, id: 0)
        let (status, ref) = cgBackend.register(shortcut, identifier: id, options: UInt32(kEventHotKeyExclusive))

        let expectedBackend: GlobalHotkey.BackendType
        if status == noErr, let ref {
            _ = cgBackend.unregister(ref)
            expectedBackend = .cgEventTap
        } else {
            expectedBackend = .carbon
        }

        let hotkey = GlobalHotkey()
        defer { hotkey.stop() }
        #expect(hotkey.backendType == expectedBackend)
    }

    // MARK: - CGEventTapHotkey ↔ GlobalHotkey onPressed bridge

    @Test func cgEventTapOnPressedBridgeTriggersGlobalHotkeyHandler() async throws {
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
            #expect(hotkey.register(shortcut))

            var callCount = 0
            hotkey.onPressed = { callCount += 1 }

            // Trigger CGEventTapHotkey's onPressed directly
            cgBackend.onPressed?()
            await Task.yield()
            #expect(callCount == 1)

            // Verify multiple calls accumulate
            cgBackend.onPressed?()
            cgBackend.onPressed?()
            await Task.yield()
            #expect(callCount == 3)
        }
    }

    // MARK: - Carbon backend registration

    @Test func carbonBackendWorksWhenCGEventTapUnavailable() async throws {
        _ = NSApplication.shared
        let cgBackend = CGEventTapHotkey()
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey),
            keyLabel: "A"
        )
        let id = EventHotKeyID(signature: 0x4D434D48, id: 0)
        let (status, ref) = cgBackend.register(shortcut, identifier: id, options: UInt32(kEventHotKeyExclusive))

        if status == noErr, let ref {
            _ = cgBackend.unregister(ref)
            // CGEventTap succeeded — verify the default path uses CGEventTap.
            let hotkey = GlobalHotkey()
            defer { hotkey.stop() }
            #expect(hotkey.backendType == .cgEventTap)
        } else {
            // CGEventTap failed — GlobalHotkey falls back to CarbonBackend.
            // Verify registration, suspend/re-register, and real Carbon event dispatch.
            let hotkey = GlobalHotkey()
            defer { hotkey.stop() }

            #expect(hotkey.backendType == .carbon)

            let carbonShortcut = KeyboardShortcut(
                keyCode: UInt32(kVK_F19),
                modifiers: UInt32(controlKey | optionKey | cmdKey),
                keyLabel: "F19"
            )
            #expect(hotkey.register(carbonShortcut))
            #expect(hotkey.currentShortcut == carbonShortcut)
            #expect(hotkey.hasActiveShortcut)

            // Suspend and re-register
            #expect(hotkey.suspend())
            #expect(hotkey.currentShortcut == nil)
            #expect(!hotkey.hasActiveShortcut)

            #expect(hotkey.register(carbonShortcut, force: true))
            #expect(hotkey.currentShortcut == carbonShortcut)
            #expect(hotkey.hasActiveShortcut)

            // Dispatch a real Carbon event through the handler
            var called = false
            hotkey.onPressed = { called = true }
            try sendHotkeyEvent(signature: 0x4D434D48, id: hotkey.eventID)
            for _ in 0..<50 where called == false { try await Task.sleep(for: .milliseconds(1)) }
            #expect(called)
        }
    }

    private func shortcut(_ key: UInt32) -> KeyboardShortcut {
        .init(keyCode: key, modifiers: UInt32(optionKey), keyLabel: "A")
    }

    private func sendHotkeyEvent(signature: OSType, id: UInt32, requireHandled: Bool = true) throws {
        var event: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                  GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &event)
        #expect(created == noErr)
        let nativeEvent = try #require(event)
        defer { ReleaseEvent(nativeEvent) }
        var identifier = EventHotKeyID(signature: signature, id: id)
        #expect(SetEventParameter(nativeEvent, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
        let result = SendEventToEventTarget(nativeEvent, GetApplicationEventTarget())
        if requireHandled { #expect(result == noErr) }
    }
}

@MainActor
private final class FakeRegistrations: HotkeyRegistrationAPI {
    var unavailable: Set<UInt32> = []
    var active: [EventHotKeyRef: KeyboardShortcut] = [:]
    var requests: [(key: UInt32, options: UInt32)] = []
    var failNextRegistration = false
    var refuseUnregister = false
    private var serial = 100

    func register(_ shortcut: KeyboardShortcut,
                  identifier: EventHotKeyID,
                  options: UInt32) -> (OSStatus, EventHotKeyRef?) {
        requests.append((shortcut.keyCode, options))
        if failNextRegistration {
            failNextRegistration = false
            return (OSStatus(eventHotKeyExistsErr), nil)
        }
        // Carbon's nonexclusive mode may succeed but deliver no events.
        if unavailable.contains(shortcut.keyCode), options & UInt32(kEventHotKeyExclusive) != 0 {
            return (OSStatus(eventHotKeyExistsErr), nil)
        }
        if active.values.contains(where: { $0.hasSameKeyCombination(as: shortcut) }) {
            return (OSStatus(eventHotKeyExistsErr), nil)
        }
        serial += 1
        let reference = EventHotKeyRef(bitPattern: serial)!
        active[reference] = shortcut
        return (noErr, reference)
    }

    func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        if refuseUnregister { return OSStatus(paramErr) }
        active.removeValue(forKey: reference)
        return noErr
    }
}
