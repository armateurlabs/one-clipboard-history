import AppKit
import OneClipboardHistoryCore
import SwiftUI
import Testing
@testable import OneClipboardHistoryApp

@Suite("Shortcut recorder lifecycle", .serialized)
@MainActor
struct ShortcutRecorderTests {
    init() { _ = NSApplication.shared }

    private func window(with button: RecorderButton) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        window.contentView = content
        button.frame = NSRect(x: 20, y: 20, width: 180, height: 26)
        content.addSubview(button)
        return window
    }

    private func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test func closingTheCachedWindowEndsRecordingExactlyOnce() {
        let button = RecorderButton()
        let window = window(with: button)
        var changes: [Bool] = []
        button.onRecordingChange = { changes.append($0) }
        button.performClick(nil)
        #expect(button.recording)
        #expect(window.firstResponder === button)

        window.close()
        button.cancelRecording()
        button.removeFromSuperview()

        #expect(!button.recording)
        #expect(changes == [true, false])
        #expect(button.title == button.shortcutLabel)
    }

    @Test func detachingTheViewRestoresWithoutSavingAnUnfinishedShortcut() {
        let button = RecorderButton()
        let window = window(with: button)
        defer { window.close() }
        var changes: [Bool] = []
        var saved: [OneClipboardHistoryApp.KeyboardShortcut] = []
        button.onRecordingChange = { changes.append($0) }
        button.onRecord = { saved.append($0) }
        button.performClick(nil)

        button.removeFromSuperview()

        #expect(!button.recording)
        #expect(changes == [true, false])
        #expect(saved.isEmpty)
    }

    @Test func swiftUIDismantlingBalancesRecordingBeforeViewRemoval() {
        let button = RecorderButton()
        let window = window(with: button)
        defer { window.close() }
        var changes: [Bool] = []
        button.onRecordingChange = { changes.append($0) }
        button.performClick(nil)

        ShortcutRecorder.dismantleNSView(button, coordinator: ())
        button.removeFromSuperview()

        #expect(!button.recording)
        #expect(changes == [true, false])
    }

    @Test func losingKeyWindowOrFirstResponderCancelsWithoutDuplicateCallbacks() {
        let button = RecorderButton()
        let window = window(with: button)
        defer { window.close() }
        var changes: [Bool] = []
        button.onRecordingChange = { changes.append($0) }
        button.performClick(nil)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        _ = window.makeFirstResponder(nil)

        #expect(!button.recording)
        #expect(changes == [true, false])
    }

    @Test func repeatedClicksAndEscapeHaveOneBalancedSession() throws {
        let button = RecorderButton()
        let window = window(with: button)
        defer { window.close() }
        var changes: [Bool] = []
        var saved: [OneClipboardHistoryApp.KeyboardShortcut] = []
        button.onRecordingChange = { changes.append($0) }
        button.onRecord = { saved.append($0) }
        button.performClick(nil)
        button.performClick(nil)
        button.keyDown(with: try key(0, characters: "a"))
        #expect(button.recording)
        #expect(changes == [true])

        button.keyDown(with: try key(53, characters: "\u{1b}"))
        button.cancelRecording()

        #expect(changes == [true, false])
        #expect(saved.isEmpty)
    }

    @Test func acceptingAReplacementEndsOnceAndRetainsItsPhysicalCombination() throws {
        let button = RecorderButton()
        let window = window(with: button)
        defer { window.close() }
        var changes: [Bool] = []
        var saved: [OneClipboardHistoryApp.KeyboardShortcut] = []
        button.onRecordingChange = { changes.append($0) }
        button.onRecord = { saved.append($0) }
        button.performClick(nil)

        button.keyDown(with: try key(12, characters: "q", modifiers: [.option, .command]))
        button.cancelRecording()

        #expect(changes == [true, false])
        #expect(saved.count == 1)
        #expect(saved.first?.keyCode == 12)
        #expect(saved.first?.label == "⌥⌘Q")
    }

    @Test func aDetachedOrRefusingWindowNeverSuspendsTheExistingBinding() {
        _ = NSApplication.shared
        let detached = RecorderButton()
        var changes: [Bool] = []
        detached.onRecordingChange = { changes.append($0) }
        detached.performClick(nil)
        #expect(!detached.recording)
        #expect(changes.isEmpty)

        let button = RecorderButton()
        button.onRecordingChange = { changes.append($0) }
        let refusing = RefusingFirstResponderWindow(contentRect: .zero, styleMask: [.titled],
            backing: .buffered, defer: false)
        refusing.isReleasedWhenClosed = false
        refusing.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        refusing.contentView?.addSubview(button)
        button.performClick(nil)

        #expect(!button.recording)
        #expect(changes.isEmpty)
        refusing.close()
    }

    @Test func movedRecorderIgnoresNotificationsFromItsFormerWindow() {
        let button = RecorderButton()
        let first = window(with: button)
        let second = window(with: RecorderButton())
        defer { first.close(); second.close() }
        var changes: [Bool] = []
        button.onRecordingChange = { changes.append($0) }
        button.performClick(nil)
        button.removeFromSuperview()
        second.contentView?.addSubview(button)
        button.performClick(nil)
        #expect(changes == [true, false, true])

        first.close()
        #expect(button.recording)
        second.close()

        #expect(!button.recording)
        #expect(changes == [true, false, true, false])
    }
}

@MainActor
private final class RefusingFirstResponderWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool { false }
}
