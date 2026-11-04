import AppKit
import MCMCore
import Testing
@testable import MCMApp

@Suite("Compact history layout", .serialized)
@MainActor
struct CompactLayoutTests {
    private func row(text: String) -> HistoryRow {
        let entry = ClipboardEntry(sourceAppName: "TextEdit", items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data(text.utf8))
        ])])
        return HistoryRow(entry: entry, presentation: .make(for: entry, includeThumbnail: false))
    }

    private func imageRow() throws -> HistoryRow {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let blue = NSColor(deviceRed: 0.15, green: 0.4, blue: 0.8, alpha: 1)
        for x in 0..<64 {
            for y in 0..<48 { bitmap.setColor(blue, atX: x, y: y) }
        }
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let entry = ClipboardEntry(items: [.init(representations: [.init(type: "public.png", data: bytes)])])
        let presentation = ClipboardPresentation.make(for: entry)
        #expect(presentation.thumbnailData != nil)
        return HistoryRow(entry: entry, presentation: presentation)
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        let own = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func table(in panel: HistoryPanelController) throws -> NSTableView {
        let tables = descendants(NSTableView.self, in: panel.window?.contentView)
        return try #require(tables.first)
    }

    private func laidOutCell(in panel: HistoryPanelController, table: NSTableView) throws -> NSTableCellView {
        let cell = try #require(panel.tableView(table, viewFor: table.tableColumns.first, row: 0) as? NSTableCellView)
        cell.frame = NSRect(x: 0, y: 0, width: 520, height: table.rowHeight)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    private func enterKey() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
    }

    @Test func compactIsTheDefaultAndRoomyLayoutRemainsAvailable() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = [row(text: "def hello():    return '你好 😄'")]
        panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil)
        let table = try table(in: panel)
        #expect(table.rowHeight == 44)
        #expect(panel.tableView(table, heightOfRow: 0) == 44)

        panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil, compactView: false)
        #expect(table.rowHeight == 56)
        #expect(panel.tableView(table, heightOfRow: 0) == 56)
    }

    @Test func compactRowsFitBothTextLinesAtEverySupportedFontSize() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = [row(text: "Ag 你好 😄 — Python indentation is preserved")]
        let table = try table(in: panel)
        let cases: [(font: Double, compact: CGFloat, roomy: CGFloat)] = [
            (10, 44, 56), (12, 44, 56), (24, 60, 70), (28, 69, 78)
        ]
        for example in cases {
            panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil,
                         fontSize: example.font, compactView: true)
            #expect(table.rowHeight == example.compact)
            let cell = try laidOutCell(in: panel, table: table)
            let fields = descendants(NSTextField.self, in: cell)
            #expect(fields.count == 3)
            for field in fields {
                let frame = field.convert(field.bounds, to: cell)
                #expect(frame.minY >= 2)
                #expect(frame.maxY <= table.rowHeight - 2)
                #expect(frame.height >= field.intrinsicContentSize.height)
            }
            #expect(cell.textField?.font?.pointSize == CGFloat(example.font))

            panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil,
                         fontSize: example.font, compactView: false)
            #expect(table.rowHeight == example.roomy)
        }
    }

    @Test func compactModeNeverChangesFontsOrShrinksTheActualImagePreview() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let row = try imageRow()
        let originalItems = row.entry.items
        let table = try table(in: panel)
        for size in [10.0, 12.0, 24.0, 28.0] {
            panel.update(rows: [row], showPreviews: true, showSizes: true, status: nil,
                         fontSize: size, compactView: false)
            let roomy = try laidOutCell(in: panel, table: table)
            let roomyPreview = try #require(descendants(NSImageView.self, in: roomy).first)
            let roomyFonts = descendants(NSTextField.self, in: roomy).map { $0.font?.pointSize }
            let dimensions = roomyPreview.image?.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }
            let imageSize = roomyPreview.frame.size

            panel.update(rows: [row], showPreviews: true, showSizes: true, status: nil,
                         fontSize: size, compactView: true)
            let compact = try laidOutCell(in: panel, table: table)
            let compactPreview = try #require(descendants(NSImageView.self, in: compact).first)
            let side = min(48, max(40, ceil(CGFloat(size) * 1.6)))
            #expect(compactPreview.image != nil)
            #expect(compactPreview.frame.size == NSSize(width: side, height: side))
            #expect(compactPreview.frame.size == imageSize)
            #expect(compactPreview.frame.minY >= 2)
            #expect(compactPreview.frame.maxY <= table.rowHeight - 2)
            #expect(compactPreview.image?.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } == dimensions)
            #expect(descendants(NSTextField.self, in: compact).map { $0.font?.pointSize } == roomyFonts)
            #expect(row.entry.items == originalItems)
        }
    }

    @Test func togglingCompactModeKeepsTheSelectedEntryAndKeyboardPaste() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = [row(text: "first"), row(text: "selected"), row(text: "third")]
        panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil)
        let table = try table(in: panel)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        var pasted: [UUID] = []
        panel.onPaste = { pasted.append($0) }

        for compact in [false, true, false, true] {
            panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil, compactView: compact)
            #expect(table.selectedRow == 1)
            table.keyDown(with: try enterKey())
        }
        #expect(pasted == Array(repeating: rows[1].id, count: 4))
    }
}
