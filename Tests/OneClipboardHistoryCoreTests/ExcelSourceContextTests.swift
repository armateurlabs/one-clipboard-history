import AppKit
import Foundation
@testable import OneClipboardHistoryCore
import Testing

@Suite("Observed Excel native-context dependency")
struct ExcelSourceContextTests {
    private func excelEntry(bundleIdentifier: String = "com.microsoft.Excel") -> ClipboardEntry {
        ClipboardEntry(items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data("OCH synthetic Excel fixture".utf8)),
            .init(type: "com.microsoft.appbundleid", data: Data(bundleIdentifier.utf8)),
            .init(type: "com.microsoft.DataObject", data: Data(repeating: 0, count: 16)),
            .init(type: "com.microsoft.ole.source.12345.0x1234", data: Data()),
            .init(type: "com.microsoft.Embed-Source", data: Data([0xD0, 0xCF, 0x11, 0xE0, 0x00, 0xFF]))
        ])])
    }

    @MainActor
    private func install(_ entry: ClipboardEntry, on board: NSPasteboard) throws {
        let items = entry.items.map { snapshot in
            let item = NSPasteboardItem()
            for value in snapshot.representations {
                #expect(item.setData(value.data, forType: .init(value.type)))
            }
            return item
        }
        board.clearContents()
        #expect(board.writeObjects(items))
    }

    @Test func dependencyRequiresTheFullObservedSignatureInOneItem() {
        let full = excelEntry()
        #expect(full.requiresExcelSourceContext)
        #expect(full.isComplete)
        #expect(!excelEntry(bundleIdentifier: "com.microsoft.Word").requiresExcelSourceContext)
        #expect(!excelEntry(bundleIdentifier: "com.microsoft.Excel\0").requiresExcelSourceContext)
        #expect(!excelEntry(bundleIdentifier: "com.microsoft.excel").requiresExcelSourceContext)
        for type in ["com.microsoft.appbundleid", "com.microsoft.DataObject", "com.microsoft.ole.source.12345.0x1234", "com.microsoft.Embed-Source"] {
            let partial = ClipboardEntry(items: [.init(representations: full.items[0].representations.filter { $0.type != type })])
            #expect(!partial.requiresExcelSourceContext)
        }
        let values = full.items[0].representations
        let split = ClipboardEntry(items: [
            .init(representations: Array(values.prefix(3))),
            .init(representations: Array(values.suffix(2)))
        ])
        #expect(!split.requiresExcelSourceContext)
        let nameOnly = ClipboardEntry(sourceAppName: "Microsoft Excel", sourceBundleIdentifier: "com.microsoft.Excel",
                                      items: [.init(representations: [values[0]])])
        #expect(!nameOnly.requiresExcelSourceContext)
    }

    @Test @MainActor func preflightAndExactCurrentWritePreserveOriginalOwner() async throws {
        let name = "app.och.tests.excel-native-context.\(UUID())"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        try install(excelEntry(), on: board)
        let service = PasteboardService(pasteboardName: name)
        let captured = try #require(try await service.captureNow())
        #expect(captured.requiresExcelSourceContext)
        let before = board.changeCount
        #expect(try await service.canPreserveNativeContext(for: captured))
        #expect(board.changeCount == before)
        try await service.write(captured)
        #expect(board.changeCount == before)
        // Explicit permission to lose context never forces a needless rewrite.
        try await service.write(captured, allowSourceContextLoss: true)
        #expect(board.changeCount == before)
    }

    @Test @MainActor func defaultHistoricalReplayRefusesBeforeChangingAnyClipboardBytes() async throws {
        let name = "app.och.tests.excel-historical-context.\(UUID())"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        board.clearContents()
        #expect(board.setString("keep current clipboard", forType: .string))
        let entry = excelEntry()
        let service = PasteboardService(pasteboardName: name)
        let before = board.changeCount
        #expect(!(try await service.canPreserveNativeContext(for: entry)))
        #expect(board.changeCount == before)
        do {
            try await service.write(entry)
            Issue.record("An observed Excel context dependency requires explicit raw-restoration permission.")
        } catch PasteboardServiceError.sourceContextRequired { }
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "keep current clipboard")
        #expect(entry.isComplete)
    }

    @Test @MainActor func explicitRawPermissionRestoresEveryOriginalTypeAndByte() async throws {
        let name = "app.och.tests.excel-explicit-raw.\(UUID())"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        board.clearContents()
        #expect(board.setString("other clipboard", forType: .string))
        let entry = excelEntry()
        let service = PasteboardService(pasteboardName: name)
        try await service.write(entry, allowSourceContextLoss: true)
        let restored = try #require(try await PasteboardService(pasteboardName: name).captureNow())
        #expect(restored.items == entry.items)
        #expect(restored.contentDigest == entry.contentDigest)
        #expect(restored.byteCount == entry.byteCount)
        #expect(restored.requiresExcelSourceContext)
        #expect(restored.isComplete)
        #expect(restored.items[0].representations.contains { $0.type.hasPrefix("com.microsoft.ole.source.") })
    }

    @Test @MainActor func changeAfterSuccessfulPreflightIsRecheckedBeforeWrite() async throws {
        let name = "app.och.tests.excel-context-race.\(UUID())"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        let entry = excelEntry()
        try install(entry, on: board)
        let service = PasteboardService(pasteboardName: name)
        #expect(try await service.canPreserveNativeContext(for: entry))
        board.clearContents()
        #expect(board.setString("new copy after preflight", forType: .string))
        let afterNewCopy = board.changeCount
        do {
            try await service.write(entry)
            Issue.record("A late clipboard change must not bypass the context guard.")
        } catch PasteboardServiceError.sourceContextRequired { }
        #expect(board.changeCount == afterNewCopy)
        #expect(board.string(forType: .string) == "new copy after preflight")
    }

    @Test func presentationSeparatesContextDependencyFromByteCompleteness() {
        let entry = excelEntry()
        let bytes = entry.items
        let digest = entry.contentDigest
        let detail = ClipboardPresentation.placeholder(for: entry).detail
        #expect(detail == L10n.format("Excel formulas need the original clipboard context · %@", L10n.text("Unknown source application")))
        #expect(entry.items == bytes)
        #expect(entry.contentDigest == digest)
        #expect(entry.isComplete)
    }
}
