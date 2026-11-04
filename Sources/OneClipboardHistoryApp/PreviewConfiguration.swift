import Foundation
import OneClipboardHistoryCore

/// These switches are read only by an explicitly launched demonstration build.
/// A fresh preferences domain makes screenshots repeatable without changing the
/// normal application's settings or a previously opened demonstration session.
struct PreviewConfiguration {
    let appearance: AppearanceMode
    let language: AppLanguage

    init(arguments: [String]) {
        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        appearance = value(after: "--demo-appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        language = value(after: "--demo-language").flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    func makeDefaults(domain: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defaults.set(appearance.rawValue, forKey: "appearanceMode")
        defaults.set(language.rawValue, forKey: "language")
        defaults.set(12.0, forKey: "historyFontSize")
        defaults.set(true, forKey: "compactView")
        defaults.set(false, forKey: "animationsEnabled")
        defaults.set(false, forKey: "persistenceEnabled")
        return defaults
    }
}
