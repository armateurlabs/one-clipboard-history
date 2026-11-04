import Foundation
import Testing
@testable import OneClipboardHistoryCore

@Suite("English and French localization")
struct LocalizationTests {
    @Test func explicitLanguagesHaveIndependentTranslations() {
        #expect(L10n.text("One Clipboard History", language: .english) == "One Clipboard History")
        #expect(L10n.text("One Clipboard History", language: .french) == "One Clipboard History")
        #expect(L10n.text("About One Clipboard History", language: .french) == "À propos de One Clipboard History")
        #expect(L10n.text("MIT License", language: .french) == "Licence MIT")
        #expect(L10n.text("Privacy Policy", language: .french) == "Politique de confidentialité")
        #expect(L10n.text("Clipboard History", language: .english) == "Clipboard History")
        #expect(L10n.text("Clipboard History", language: .french) == "Historique du presse-papiers")
        #expect(L10n.text("History font size", language: .french) == "Taille de police de l’historique")
        #expect(L10n.text("Off by default: the window appears and disappears instantly.", language: .french)
            == "Désactivé par défaut : la fenêtre apparaît et disparaît instantanément.")
    }

    @Test func formatsPreserveSourceNamesAndNumericArguments() {
        #expect(L10n.format("Copied from %@", language: .english, arguments: ["Word"]) == "Copied from Word")
        #expect(L10n.format("Copied from %@", language: .french, arguments: ["Word"]) == "Copié depuis Word")
        #expect(L10n.format("%ld files · %@", language: .french, arguments: [2, "alpha.txt, β.txt"])
            == "2 fichiers · alpha.txt, β.txt")
        #expect(L10n.text("Unregistered source phrase", language: .french) == "Unregistered source phrase")
    }

    @Test func systemLanguageResolvesSupportedVariantsAndFallsBackToEnglish() {
        #expect(L10n.resolvedLanguageIdentifier(for: .system, preferredLanguages: ["fr-CA", "en-US"]) == "fr")
        #expect(L10n.resolvedLanguageIdentifier(for: .system, preferredLanguages: ["en-GB", "fr"]) == "en")
        #expect(L10n.resolvedLanguageIdentifier(for: .system, preferredLanguages: ["de-DE", "fr-FR"]) == "fr")
        #expect(L10n.resolvedLanguageIdentifier(for: .system, preferredLanguages: ["ja-JP"]) == "en")
        #expect(L10n.resolvedLanguageIdentifier(for: .french, preferredLanguages: ["en-US"]) == "fr")
        #expect(L10n.locale(for: .english).language.languageCode?.identifier == "en")
        #expect(L10n.locale(for: .french).language.languageCode?.identifier == "fr")
    }

    @Test func catalogsHaveMatchingKeysAndFormatSignatures() throws {
        let english = try catalog("en")
        let french = try catalog("fr")
        #expect(english.count >= 100)
        #expect(Set(english.keys) == Set(french.keys))
        let expression = try NSRegularExpression(pattern: "%[@a-zA-Z]+")
        for (key, value) in english {
            #expect(value == key)
            let translated = try #require(french[key])
            #expect(!translated.isEmpty)
            func formats(_ string: String) -> [String] {
                expression.matches(in: string, range: NSRange(string.startIndex..., in: string)).map {
                    String(string[Range($0.range, in: string)!])
                }
            }
            #expect(formats(value) == formats(translated), "Format mismatch for \(key)")
        }
    }

    @Test func everyLiteralLocalizationAndStatusKeyHasBothTranslations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let english = try catalog("en")
        let french = try catalog("fr")
        for key in ["Preview mode: copied to a private clipboard.",
                    "Entry copied. Allow automatic paste in Settings or paste with ⌘V."] {
            #expect(english[key] != nil)
            #expect(french[key] != nil)
        }
        let expression = try NSRegularExpression(pattern: #"(?:L10n\.(?:text|format)\(|setStatus\(|shortcutError = )\s*"((?:[^"\\]|\\.)*)""#)
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let encoded = String(source[Range(match.range(at: 1), in: source)!])
                let key = try JSONDecoder().decode(String.self, from: Data(("\"" + encoded + "\"").utf8))
                #expect(english[key] != nil, "Missing English key: \(key)")
                #expect(french[key] != nil, "Missing French key: \(key)")
            }
        }
    }

    private func catalog(_ language: String) throws -> [String: String] {
        let path = try #require(Bundle.module.path(forResource: "Localizable", ofType: "strings", inDirectory: "\(language).lproj"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
