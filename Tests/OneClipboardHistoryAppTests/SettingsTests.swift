import AppKit
import Carbon
import Testing
import OneClipboardHistoryCore
@testable import OneClipboardHistoryApp

@Suite("Native settings", .serialized)
@MainActor
struct SettingsTests {
    private func isolatedDefaults() -> (String, UserDefaults) {
        let name = "com.arthur.mcm.tests.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func event(_ code: UInt16, characters: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    @Test func defaultsMatchThePersonalClipboardWorkflow() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)

        #expect(settings.historyLimit == 20)
        #expect(settings.budgetMegabytes == 256)
        #expect(settings.showPreviews)
        #expect(settings.showSizes)
        #expect(settings.compactView)
        #expect(settings.hideAfterPasting)
        #expect(!settings.positionAtPointer)
        #expect(settings.pointerQuadrant == .bottomRight)
        #expect(!settings.persistenceEnabled)
        #expect(settings.historyFontSize == 12)
        #expect(!settings.animationsEnabled)
        #expect(settings.appearanceMode == .system)
        #expect(settings.language == .system)
        #expect(settings.shortcut.label == "⌥A")
        #expect(settings.shortcut.modifiers == UInt32(optionKey))
        #expect(settings.savedFrame == nil)
    }

    @Test func settingsAndWindowFrameSurviveReload() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        var changes = 0
        settings.onChange = { changes += 1 }
        settings.historyLimit = 45
        settings.budgetMegabytes = 512
        settings.showPreviews = false
        settings.showSizes = false
        settings.hideAfterPasting = false
        settings.positionAtPointer = true
        settings.persistenceEnabled = true
        settings.shortcut = .init(keyCode: 49, modifiers: UInt32(controlKey | optionKey), keyLabel: "Espace")
        let frame = NSRect(x: 100, y: 80, width: 520, height: 640)
        settings.savedFrame = frame
        let reloaded = AppSettings(defaults: defaults)

        #expect(changes == 8)
        #expect(reloaded.historyLimit == 45)
        #expect(reloaded.budgetMegabytes == 512)
        #expect(!reloaded.showPreviews)
        #expect(!reloaded.showSizes)
        #expect(!reloaded.hideAfterPasting)
        #expect(reloaded.positionAtPointer)
        #expect(reloaded.persistenceEnabled)
        #expect(reloaded.shortcut.label == "⌃⌥" + L10n.text("Space"))
        #expect(reloaded.savedFrame == frame)
    }

    @Test func persistedNumericLimitsAreClampedBeforeTheyCanOverflow() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Int.max, forKey: "historyLimit")
        defaults.set(Int.max, forKey: "budgetMegabytes")
        let large = AppSettings(defaults: defaults)
        #expect(large.historyLimit == 1_000_000)
        #expect(large.budgetMegabytes == 1_048_576)
        #expect(Int64(large.budgetMegabytes) * 1_048_576 == 1_099_511_627_776)

        defaults.set(-20, forKey: "historyLimit")
        defaults.set(0, forKey: "budgetMegabytes")
        let invalid = AppSettings(defaults: defaults)
        #expect(invalid.historyLimit == 1)
        #expect(invalid.budgetMegabytes == 1)
    }

    @Test func malformedShortcutFallsBackToTheDefault() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data([0xFF, 0x00]), forKey: "shortcut")
        #expect(AppSettings(defaults: defaults).shortcut.label == "⌥A")
    }

    @Test func recorderRequiresAModifierAndPreservesTheRecordedCombination() throws {
        _ = NSApplication.shared
        #expect(KeyboardShortcut(event: try event(0, characters: "a", flags: [])) == nil)
        #expect(KeyboardShortcut(event: try event(0, characters: "A", flags: .shift)) == nil)
        #expect(KeyboardShortcut(event: try event(53, characters: "\u{1b}", flags: .option)) == nil)
        let recorded = try #require(KeyboardShortcut(event: try event(
            12, characters: "q", flags: [.control, .option, .shift, .command, .capsLock]
        )))
        #expect(recorded.keyCode == 12)
        #expect(recorded.modifiers == UInt32(controlKey | optionKey | shiftKey | cmdKey))
        #expect(recorded.label == "⌃⌥⇧⌘Q")
    }

    @Test func displayPreferencesPersistAndNotifyImmediately() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        var changes = 0
        settings.onChange = { changes += 1 }
        settings.historyFontSize = 22
        settings.animationsEnabled = true
        settings.language = .french

        let reloaded = AppSettings(defaults: defaults)
        #expect(changes == 3)
        #expect(reloaded.historyFontSize == 22)
        #expect(reloaded.animationsEnabled)
        #expect(reloaded.language == .french)
        #expect(defaults.double(forKey: "historyFontSize") == 22)
        #expect(defaults.bool(forKey: "animationsEnabled"))
        #expect(defaults.string(forKey: "language") == "fr")
    }

    @Test func fontSizeIsNormalizedOnLoadAndLiveAssignment() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        for (stored, expected) in [(0.0, 10.0), (100.0, 28.0), (Double.nan, 12.0),
                                   (Double.infinity, 12.0), (-Double.infinity, 12.0)] {
            defaults.set(stored, forKey: "historyFontSize")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.historyFontSize == expected)
            settings.historyFontSize = stored
            #expect(settings.historyFontSize == expected)
            #expect(defaults.double(forKey: "historyFontSize") == expected)
        }
    }

    @Test func unsupportedLanguageFallsBackToSystemAndSpaceLabelUsesLocalization() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unsupported-language", forKey: "language")
        #expect(AppSettings(defaults: defaults).language == .system)
        let legacy = KeyboardShortcut(keyCode: 49, modifiers: UInt32(optionKey), keyLabel: "Espace")
        #expect(legacy.label == "⌥" + L10n.text("Space"))
    }

    @Test func pointerQuadrantsPersistAndNotifyWithoutEnablingPointerMode() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        var changes = 0
        settings.onChange = { changes += 1 }

        for quadrant in PointerQuadrant.allCases {
            settings.pointerQuadrant = quadrant
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.pointerQuadrant == quadrant)
            #expect(defaults.string(forKey: "pointerQuadrant") == quadrant.rawValue)
            #expect(!reloaded.positionAtPointer)
        }
        #expect(changes == PointerQuadrant.allCases.count)

        settings.pointerQuadrant = .topLeft
        settings.positionAtPointer = true
        settings.positionAtPointer = false
        #expect(settings.pointerQuadrant == .topLeft)
        #expect(AppSettings(defaults: defaults).pointerQuadrant == .topLeft)
    }

    @Test func invalidPointerQuadrantFallsBackWithoutChangingSavedFont() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("outside-screen", forKey: "pointerQuadrant")
        defaults.set(22.0, forKey: "historyFontSize")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.pointerQuadrant == .bottomRight)
        #expect(settings.historyFontSize == 22)
    }

    @Test func compactViewDefaultsOnForExistingPreferencesWithoutChangingContentSizes() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(22.0, forKey: "historyFontSize")
        defaults.set(true, forKey: "showPreviews")
        defaults.set(45, forKey: "historyLimit")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.compactView)
        #expect(settings.historyFontSize == 22)
        #expect(settings.showPreviews)
        #expect(settings.historyLimit == 45)
    }

    @Test func compactViewPersistsAndNotifiesWithoutChangingTextOrPreviews() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(18.0, forKey: "historyFontSize")
        defaults.set(false, forKey: "showPreviews")
        let settings = AppSettings(defaults: defaults)
        var changes = 0
        settings.onChange = { changes += 1 }

        for compact in [false, true] {
            settings.compactView = compact
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.compactView == compact)
            #expect(defaults.bool(forKey: "compactView") == compact)
            #expect(reloaded.historyFontSize == 18)
            #expect(!reloaded.showPreviews)
        }
        #expect(changes == 2)
    }

    @Test func appearanceModesPersistAndNotifyWithoutChangingOtherPreferences() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(22.0, forKey: "historyFontSize")
        defaults.set(false, forKey: "compactView")
        defaults.set(false, forKey: "showPreviews")
        defaults.set(false, forKey: "hideAfterPasting")
        let settings = AppSettings(defaults: defaults)
        var changes = 0
        settings.onChange = { changes += 1 }

        for mode in [AppearanceMode.dark, .light, .system] {
            settings.appearanceMode = mode
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.appearanceMode == mode)
            #expect(defaults.string(forKey: "appearanceMode") == mode.rawValue)
            #expect(reloaded.historyFontSize == 22)
            #expect(!reloaded.compactView)
            #expect(!reloaded.showPreviews)
            #expect(!reloaded.hideAfterPasting)
        }
        #expect(changes == 3)
        #expect(AppearanceMode.allCases.count == 3)
    }

    @Test func appearanceDefaultsToSystemForExistingOrInvalidPreferences() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(18.0, forKey: "historyFontSize")
        #expect(AppSettings(defaults: defaults).appearanceMode == .system)
        defaults.set("unsupported-appearance", forKey: "appearanceMode")
        let invalid = AppSettings(defaults: defaults)
        #expect(invalid.appearanceMode == .system)
        #expect(invalid.historyFontSize == 18)
    }
}
