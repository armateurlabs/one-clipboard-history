import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case french = "fr"
}

/// App-owned strings use explicit language bundles, so choosing a language does
/// not mutate AppleLanguages or require restarting the application. Clipboard
/// bytes and source-provided text never pass through this layer.
public enum L10n {
    public static let languageDidChange = Notification.Name("com.arthur.mcm.languageDidChange")
    private static let state = LanguageState()

    public static func configure(_ language: AppLanguage) {
        guard state.set(language) else { return }
        NotificationCenter.default.post(name: languageDidChange, object: nil)
    }

    public static var currentLocale: Locale { locale(for: state.language) }

    public static func text(_ key: String) -> String {
        text(key, language: state.language)
    }

    public static func text(_ key: String, language: AppLanguage) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: "Localizable")
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, language: state.language, arguments: arguments)
    }

    public static func format(_ key: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        String(format: text(key, language: language), locale: locale(for: language), arguments: arguments)
    }

    public static func locale(for language: AppLanguage) -> Locale {
        Locale(identifier: identifier(for: language))
    }

    static func resolvedLanguageIdentifier(for language: AppLanguage, preferredLanguages: [String]) -> String {
        guard language == .system else { return language.rawValue }
        return Bundle.preferredLocalizations(from: ["en", "fr"], forPreferences: preferredLanguages).first ?? "en"
    }

    private static func identifier(for language: AppLanguage) -> String {
        resolvedLanguageIdentifier(for: language, preferredLanguages: Locale.preferredLanguages)
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        switch identifier(for: language) {
        case "fr": state.frenchBundle
        default: state.englishBundle
        }
    }

    private final class LanguageState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AppLanguage = .system
        let englishBundle: Bundle
        let frenchBundle: Bundle

        init() {
            englishBundle = Bundle.module.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
            frenchBundle = Bundle.module.path(forResource: "fr", ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
        }

        var language: AppLanguage {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ language: AppLanguage) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard value != language else { return false }
            value = language
            return true
        }
    }
}
