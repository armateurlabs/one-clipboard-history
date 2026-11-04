import AppKit
import ImageIO
import OneClipboardHistoryCore
import Testing
@testable import OneClipboardHistoryApp

@Suite("Isolated screenshot preview", .serialized)
@MainActor
struct PreviewTests {
    @Test func previewOptionsUseASeparateDomainAndDeterministicDisplayDefaults() {
        let configuration = PreviewConfiguration(arguments: ["--demo-language", "fr", "--demo-appearance", "dark"])
        #expect(configuration.appearance == .dark)
        #expect(configuration.language == .french)
        let domain = "com.armateurlabs.oneclipboardhistory.tests.preview.\(UUID().uuidString)"
        let defaults = configuration.makeDefaults(domain: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.appearanceMode == .dark)
        #expect(settings.language == .french)
        #expect(settings.historyFontSize == 12)
        #expect(settings.historyDensity == .compact)
        #expect(!settings.persistenceEnabled)
        #expect(!settings.animationsEnabled)
        #expect(settings.savedFrame == nil)
        let fallback = PreviewConfiguration(arguments: ["--demo-language", "xx", "--demo-appearance"])
        #expect(fallback.language == .english)
        #expect(fallback.appearance == .system)
    }

    @Test func previewFixturesContainIndependentRichTextOriginalImageAndExistingFileReferences() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = try DemoFixtures.entries(in: directory)
        #expect(entries.count == 8)
        #expect(entries.allSatisfy { $0.isComplete })
        let python = try #require(entries[1].items.first?.representations.first?.data)
        #expect(String(data: python, encoding: .utf8) == "def greet(name):\n    return f\"Hello, {name}! 👋\"\n")
        let rich = entries[2].items.flatMap(\.representations)
        #expect(Set(rich.map(\.type)) == Set([
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue,
            NSPasteboard.PasteboardType.html.rawValue
        ]))
        let rtf = try #require(rich.first { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }?.data)
        let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(!decoded.string.isEmpty)
        #expect(decoded.attribute(.font, at: 0, effectiveRange: nil) is NSFont)
        let png = try #require(entries[3].items.first?.representations.first?.data)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320)
        #expect(image.height == 240)
        #expect(ClipboardPresentation.make(for: entries[3]).thumbnailData != nil)
        #expect(ClipboardPresentation.fileURLs(for: entries[4]).count == 1)
        #expect(ClipboardPresentation.fileURLs(for: entries[5]).count == 2)
        for entry in entries {
            #expect(ClipboardPresentation.missingFiles(for: entry).isEmpty)
            for file in ClipboardPresentation.fileURLs(for: entry) {
                #expect(file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
            }
        }
    }
}
