import Foundation
@testable import OneClipboardHistoryCore
import Testing

@Suite("Lossless bounded history")
struct HistoryTests {
    private func entry(_ text: String, id: UUID = UUID()) -> ClipboardEntry {
        ClipboardEntry(id: id, items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])])
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mcm-history-test-\(UUID())")
    }

    @Test func defaultsToTwentyEntriesAnd256MiB() {
        let configuration = HistoryConfiguration()
        #expect(configuration.maxCount == 20)
        #expect(configuration.maxBytes == 256 * 1024 * 1024)
    }

    @Test func insertionIsNewestFirstAndEvictsWholeEntries() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try HistoryRepository(directory: url)
        var inserted: [ClipboardEntry] = []
        for number in 0..<25 {
            let value = entry("entry \(number)")
            inserted.append(value)
            _ = try await repository.insert(value)
        }
        let history = await repository.currentEntries()
        #expect(history.count == 20)
        #expect(history.map(\.id) == Array(inserted.suffix(20).reversed()).map(\.id))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func exactDuplicateKeepsIdentityAndMovesToFront() async throws {
        let repository = try HistoryRepository(directory: directory())
        let first = entry("same")
        let second = entry("other")
        _ = try await repository.insert(first)
        _ = try await repository.insert(second)
        let duplicate = ClipboardEntry(
            sourceAppName: "Another application", sourceBundleIdentifier: "example.other",
            items: first.items
        )
        let result = try await repository.insert(duplicate)
        #expect(result.entries.map(\.id) == [first.id, second.id])
        #expect(first.contentDigest == duplicate.contentDigest)
    }

    @Test func equalTextWithDifferentFormattingRemainsDistinct() async throws {
        let repository = try HistoryRepository(directory: directory())
        let plain = entry("hello")
        let rich = ClipboardEntry(items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data("hello".utf8)),
            .init(type: "public.html", data: Data("<b>hello</b>".utf8))
        ])])
        _ = try await repository.insert(plain)
        let result = try await repository.insert(rich)
        #expect(result.entries.count == 2)
        #expect(plain.contentDigest != rich.contentDigest)
    }

    @Test func representationPreferenceAndItemOrderAreBothSignificant() {
        let text = ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("text".utf8))
        let html = ClipboardRepresentation(type: "public.html", data: Data("<p>text</p>".utf8))
        let original = ClipboardEntry(items: [.init(representations: [text, html])])
        let reorderedTypes = ClipboardEntry(items: [.init(representations: [html, text])])
        #expect(original.contentDigest != reorderedTypes.contentDigest)
        #expect(!original.hasIdenticalContent(to: reorderedTypes))
        let first = ClipboardEntry(items: [.init(representations: [text]), .init(representations: [html])])
        let second = ClipboardEntry(items: [.init(representations: [html]), .init(representations: [text])])
        #expect(first.contentDigest != second.contentDigest)
    }

    @Test func copyingOnlyAChangedFormatPreferenceKeepsBothOriginalOrders() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try HistoryRepository(directory: url, persistenceEnabled: true)
        let text = ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("text".utf8))
        let html = ClipboardRepresentation(type: "public.html", data: Data("<b>text</b>".utf8))
        let plainPreferred = ClipboardEntry(items: [.init(representations: [text, html])])
        let richPreferred = ClipboardEntry(items: [.init(representations: [html, text])])
        _ = try await repository.insert(plainPreferred)
        let result = try await repository.insert(richPreferred)
        #expect(result.entries.map(\.id) == [richPreferred.id, plainPreferred.id])
        #expect(result.entries[0].items[0].representations == [html, text])
        #expect(result.entries[1].items[0].representations == [text, html])
        let reopened = try HistoryRepository(directory: url, persistenceEnabled: true)
        let restored = try await reopened.load()
        #expect(restored.map(\.id) == [richPreferred.id, plainPreferred.id])
        #expect(restored[0].items == richPreferred.items)
        #expect(restored[1].items == plainPreferred.items)
    }

    @Test func digestUsesUnambiguousLengthPrefixes() {
        let first = ClipboardEntry(items: [.init(representations: [.init(type: "a", data: Data("bc".utf8))])])
        let second = ClipboardEntry(items: [.init(representations: [.init(type: "ab", data: Data("c".utf8))])])
        #expect(first.contentDigest != second.contentDigest)
    }

    @Test func oversizedEntryIsRejectedWithoutDiscardingFormats() async throws {
        let repository = try HistoryRepository(directory: directory(), configuration: .init(maxBytes: 10))
        let previous = entry("keep")
        _ = try await repository.insert(previous)
        let tooLarge = ClipboardEntry(items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data(repeating: 1, count: 6)),
            .init(type: "public.html", data: Data(repeating: 2, count: 6))
        ])])
        let result = try await repository.insert(tooLarge)
        #expect(result.rejectedReason != nil)
        #expect(result.entries.map(\.id) == [previous.id])
        #expect(tooLarge.items[0].representations.count == 2)
    }

    @Test func byteBudgetEvictsOldestWholeEntry() async throws {
        let repository = try HistoryRepository(directory: directory(), configuration: .init(maxCount: 20, maxBytes: 15))
        _ = try await repository.insert(entry("12345678"))
        let newest = entry("abcdefgh")
        let result = try await repository.insert(newest)
        #expect(result.entries.map(\.id) == [newest.id])
    }

    @Test func promotingAndReconfigurationPreserveRawSnapshots() async throws {
        let repository = try HistoryRepository(directory: directory())
        let a = entry("a"), b = entry("b"), c = entry("c")
        for value in [a, b, c] { _ = try await repository.insert(value) }
        let promoted = try await repository.promote(id: a.id)
        #expect(promoted.map(\.id) == [a.id, c.id, b.id])
        let resized = try await repository.configure(.init(maxCount: 2), persistenceEnabled: false)
        #expect(resized.map(\.id) == [a.id, c.id])
        #expect(resized[0].items == a.items)
        let removed = try await repository.remove(id: a.id)
        #expect(removed.map(\.id) == [c.id])
        let cleared = try await repository.clear()
        #expect(cleared.isEmpty)
    }

    @Test func snapshotPreservesPythonOfficePrivateDataAndMetadata() throws {
        let python = Data("def café(x):\r\n\tif x:\r\n        return '🐍'\r\n\r\n".utf8)
        let privateData = Data([0, 255, 1, 0, 128, 42])
        let entry = ClipboardEntry(
            sourceAppName: "Microsoft Excel", sourceBundleIdentifier: "com.microsoft.Excel",
            items: [
                .init(representations: [
                    .init(type: "public.utf8-plain-text", data: python),
                    .init(type: "com.microsoft.excel.private-format", data: privateData),
                    .init(type: "public.rtf", data: Data("{\\rtf1\\b hello}".utf8))
                ]),
                .init(representations: [.init(type: "public.png", data: Data([0x89, 0x50, 0, 0xFF]))])
            ]
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let restored = try PropertyListDecoder().decode(ClipboardEntry.self, from: encoder.encode(entry))
        #expect(restored.items == entry.items)
        #expect(restored.items[0].representations[0].data == python)
        #expect(restored.sourceBundleIdentifier == entry.sourceBundleIdentifier)
        #expect(restored.sourceAppName == entry.sourceAppName)
        #expect(restored.capturedAt == entry.capturedAt)
        #expect(restored.contentDigest == entry.contentDigest)
        #expect(restored.isComplete)
    }

    @Test func incompleteCaptureRemainsExplicitAndDistinct() {
        let item = ClipboardItemSnapshot(representations: [.init(type: "public.utf8-plain-text", data: Data("x".utf8))])
        let complete = ClipboardEntry(items: [item])
        let incomplete = ClipboardEntry(items: [item], missingTypes: ["com.microsoft.private"])
        #expect(!incomplete.isComplete)
        #expect(complete.contentDigest != incomplete.contentDigest)
        #expect(!ClipboardEntry(items: []).isComplete)
        #expect(!ClipboardEntry(items: [.init(representations: [])]).isComplete)
    }
}
