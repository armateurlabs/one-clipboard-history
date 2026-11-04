import AppKit
import Carbon
import Testing
@testable import OneClipboardHistoryApp

@Suite("Native hotkey dispatch", .serialized)
@MainActor
struct GlobalHotkeyTests {
    @Test func registeredHandlerRoutesOnlyOurSignature() async throws {
        _ = NSApplication.shared
        let hotkey = GlobalHotkey()
        defer { hotkey.stop() }
        var count = 0
        hotkey.onPressed = { count += 1 }
        try sendHotkeyEvent(signature: 0x4D434D48)
        for _ in 0..<50 where count == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(count == 1)
        try sendHotkeyEvent(signature: 0x554E4B4E, requireHandled: false)
        await Task.yield()
        #expect(count == 1)
    }

    @Test func stoppingRemovesTheCarbonHandler() async throws {
        _ = NSApplication.shared
        let hotkey = GlobalHotkey()
        var called = false
        hotkey.onPressed = { called = true }
        hotkey.stop()
        try sendHotkeyEvent(signature: 0x4D434D48, requireHandled: false)
        await Task.yield()
        #expect(!called)
    }

    private func sendHotkeyEvent(signature: OSType, requireHandled: Bool = true) throws {
        var event: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                  GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &event)
        #expect(created == noErr)
        let nativeEvent = try #require(event)
        defer { ReleaseEvent(nativeEvent) }
        var identifier = EventHotKeyID(signature: signature, id: 1)
        #expect(SetEventParameter(nativeEvent, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
        let result = SendEventToEventTarget(nativeEvent, GetApplicationEventTarget())
        if requireHandled { #expect(result == noErr) }
    }
}
