import AppKit
import Foundation
import OneClipboardHistoryCore
import Testing
@testable import OneClipboardHistoryApp

@Suite("About metadata and bundled documents", .serialized)
@MainActor
struct AppInformationTests {
    @Test func nativeAboutOptionsExposeVersionAndResolvableOfflineDocuments() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = directory.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.armateurlabs.oneclipboardhistory.tests.about",
            "CFBundleName": AppInformation.name,
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Contents/Info.plist"))
        try Data("MIT License\nCopyright (c) 2026 Armateur Labs\n".utf8).write(to: resources.appendingPathComponent("LICENSE.txt"))
        try Data("Your clipboard remains on your Mac.\n".utf8).write(to: resources.appendingPathComponent("PRIVACY.txt"))
        let bundle = try #require(Bundle(url: directory))
        let options = AppInformation.aboutOptions(bundle: bundle)
        #expect(options[.applicationName] as? String == "One Clipboard History")
        #expect(options[.applicationVersion] as? String == "1.2.3")
        #expect(options[.version] as? String == "42")
        let credits = try #require(options[.credits] as? NSAttributedString)
        #expect(credits.string.contains("Armateur Labs"))
        var links: [URL] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links.contains(AppInformation.repositoryURL))
        let documents = links.filter(\.isFileURL)
        #expect(documents.count == 2)
        #expect(Set(documents.map(\.lastPathComponent)) == ["LICENSE.txt", "PRIVACY.txt"])
        for document in documents {
            #expect(try !Data(contentsOf: document).isEmpty)
        }
    }
}
