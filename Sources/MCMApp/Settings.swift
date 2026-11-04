import AppKit
import Carbon
import Combine
import MCMCore

enum PointerQuadrant: String, CaseIterable, Sendable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

struct KeyboardShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    @MainActor static var initial: KeyboardShortcut {
        KeyboardShortcut(keyCode: KeyboardLayout.keyCode(for: "a") ?? 0, modifiers: UInt32(optionKey), keyLabel: "A")
    }

    var label: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (keyCode == 49 ? L10n.text("Space") : keyLabel)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty,
              ![48, 51, 53, 117].contains(Int(event.keyCode)) else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        let labels: [UInt16: String] = [36: "↩", 49: "Space", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        keyLabel = labels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "\(event.keyCode)"
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?
    var onShortcutRecordingChange: ((Bool) -> Void)?
    @Published var historyLimit: Int { didSet { save() } }
    @Published var budgetMegabytes: Int { didSet { save() } }
    @Published var showPreviews: Bool { didSet { save() } }
    @Published var showSizes: Bool { didSet { save() } }
    @Published var compactView: Bool { didSet { save() } }
    @Published var hideAfterPasting: Bool { didSet { save() } }
    @Published var positionAtPointer: Bool { didSet { save() } }
    @Published var pointerQuadrant: PointerQuadrant { didSet { save() } }
    @Published var persistenceEnabled: Bool { didSet { save() } }
    @Published var historyFontSize: Double {
        didSet {
            let normalized = Self.normalizedFontSize(historyFontSize)
            if historyFontSize != normalized { historyFontSize = normalized }
            save()
        }
    }
    @Published var animationsEnabled: Bool { didSet { save() } }
    @Published var appearanceMode: AppearanceMode { didSet { save() } }
    @Published var language: AppLanguage { didSet { save() } }
    @Published var shortcut: KeyboardShortcut { didSet { save() } }
    @Published var shortcutError: String?
    var savedFrame: NSRect? {
        get { defaults.string(forKey: "windowFrame").map(NSRectFromString) }
        set { defaults.set(newValue.map(NSStringFromRect), forKey: "windowFrame") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "historyLimit": 20, "budgetMegabytes": 256, "showPreviews": true,
            "showSizes": true, "compactView": true, "hideAfterPasting": true, "positionAtPointer": false,
            "persistenceEnabled": false, "historyFontSize": 12.0,
            "pointerQuadrant": PointerQuadrant.bottomRight.rawValue,
            "animationsEnabled": false, "appearanceMode": AppearanceMode.system.rawValue,
            "language": AppLanguage.system.rawValue
        ])
        historyLimit = max(1, min(defaults.integer(forKey: "historyLimit"), 1_000_000))
        budgetMegabytes = max(1, min(defaults.integer(forKey: "budgetMegabytes"), 1_048_576))
        showPreviews = defaults.bool(forKey: "showPreviews")
        showSizes = defaults.bool(forKey: "showSizes")
        compactView = defaults.bool(forKey: "compactView")
        hideAfterPasting = defaults.bool(forKey: "hideAfterPasting")
        positionAtPointer = defaults.bool(forKey: "positionAtPointer")
        pointerQuadrant = defaults.string(forKey: "pointerQuadrant").flatMap(PointerQuadrant.init(rawValue:)) ?? .bottomRight
        persistenceEnabled = defaults.bool(forKey: "persistenceEnabled")
        historyFontSize = Self.normalizedFontSize(defaults.double(forKey: "historyFontSize"))
        animationsEnabled = defaults.bool(forKey: "animationsEnabled")
        appearanceMode = defaults.string(forKey: "appearanceMode").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        language = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(KeyboardShortcut.self, from: $0) } ?? .initial
    }

    private func save() {
        defaults.set(max(1, min(historyLimit, 1_000_000)), forKey: "historyLimit")
        defaults.set(max(1, min(budgetMegabytes, 1_048_576)), forKey: "budgetMegabytes")
        defaults.set(showPreviews, forKey: "showPreviews")
        defaults.set(showSizes, forKey: "showSizes")
        defaults.set(compactView, forKey: "compactView")
        defaults.set(hideAfterPasting, forKey: "hideAfterPasting")
        defaults.set(positionAtPointer, forKey: "positionAtPointer")
        defaults.set(pointerQuadrant.rawValue, forKey: "pointerQuadrant")
        defaults.set(persistenceEnabled, forKey: "persistenceEnabled")
        defaults.set(Self.normalizedFontSize(historyFontSize), forKey: "historyFontSize")
        defaults.set(animationsEnabled, forKey: "animationsEnabled")
        defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
        defaults.set(language.rawValue, forKey: "language")
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut")
        onChange?()
    }

    private static func normalizedFontSize(_ value: Double) -> Double {
        value.isFinite ? min(28, max(10, value)) : 12
    }
}

@MainActor
private enum KeyboardLayout {
    static func keyCode(for character: String) -> UInt32? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code: UInt16 in 0..<128 {
            var deadKey: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 8)
            var length = 0
            let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey,
                                        characters.count, &length, &characters)
            if result == noErr, String(utf16CodeUnits: characters, count: length).lowercased() == character {
                return UInt32(code)
            }
        }
        return nil
    }
}
