import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case russian = "ru"
    case simplifiedChinese = "zh-Hans"
    case german = "de"

    public static let localizedLanguages = allCases.filter { $0 != .system }

    /// Endonyms keep the language selector recognizable after any language change.
    public var displayName: String {
        switch self {
        case .system: L10n.text("System language")
        case .english: "English"
        case .french: "Français"
        case .spanish: "Español"
        case .italian: "Italiano"
        case .russian: "Русский"
        case .simplifiedChinese: "简体中文"
        case .german: "Deutsch"
        }
    }
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
        return Bundle.preferredLocalizations(
            from: AppLanguage.localizedLanguages.map(\.rawValue), forPreferences: preferredLanguages
        ).first ?? "en"
    }

    private static func identifier(for language: AppLanguage) -> String {
        resolvedLanguageIdentifier(for: language, preferredLanguages: Locale.preferredLanguages)
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        state.bundles[identifier(for: language)] ?? state.englishBundle
    }

    private final class LanguageState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AppLanguage = .system
        let englishBundle: Bundle
        let bundles: [String: Bundle]

        init() {
            let fallback = Bundle.module.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
            englishBundle = fallback
            bundles = Dictionary(uniqueKeysWithValues: AppLanguage.localizedLanguages.map { language in
                let bundle = Bundle.module.path(forResource: language.rawValue, ofType: "lproj")
                    .flatMap(Bundle.init(path:)) ?? fallback
                return (language.rawValue, bundle)
            })
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
