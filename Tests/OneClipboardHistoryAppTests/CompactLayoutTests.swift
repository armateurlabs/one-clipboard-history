import AppKit
import OneClipboardHistoryCore
import Testing
@testable import OneClipboardHistoryApp

@Suite("History density layouts", .serialized)
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

    @Test func compactIsTheDefaultAndNormalAndLargeRemainAvailable() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = [row(text: "def hello():    return '你好 😄'")]
        panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil)
        let table = try table(in: panel)
        let compact = try laidOutCell(in: panel, table: table)
        let title = try #require(compact.textField)
        #expect(table.rowHeight == ceil(title.intrinsicContentSize.height) + 4)
        #expect(table.rowHeight < 44)

        panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil, density: .normal)
        #expect(table.rowHeight == 44)
        #expect(panel.tableView(table, heightOfRow: 0) == 44)

        panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil, density: .large)
        #expect(table.rowHeight == 56)
        #expect(panel.tableView(table, heightOfRow: 0) == 56)
    }

    @Test func normalRowsFitBothTextLinesAtEverySupportedFontSize() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = [row(text: "Ag 你好 😄 — Python indentation is preserved")]
        let table = try table(in: panel)
        let cases: [(font: Double, compact: CGFloat, roomy: CGFloat)] = [
            (10, 44, 56), (12, 44, 56), (24, 60, 70), (28, 69, 78)
        ]
        for example in cases {
            panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil,
                         fontSize: example.font, density: .normal)
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
                         fontSize: example.font, density: .large)
            #expect(table.rowHeight == example.roomy)
        }
    }

    @Test func normalAndLargeNeverChangeFontsOrShrinkTheActualImagePreview() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let row = try imageRow()
        let originalItems = row.entry.items
        let table = try table(in: panel)
        for size in [10.0, 12.0, 24.0, 28.0] {
            panel.update(rows: [row], showPreviews: true, showSizes: true, status: nil,
                         fontSize: size, density: .large)
            let roomy = try laidOutCell(in: panel, table: table)
            let roomyPreview = try #require(descendants(NSImageView.self, in: roomy).first)
            let roomyFonts = descendants(NSTextField.self, in: roomy).map { $0.font?.pointSize }
            let dimensions = roomyPreview.image?.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }
            let imageSize = roomyPreview.frame.size

            panel.update(rows: [row], showPreviews: true, showSizes: true, status: nil,
                         fontSize: size, density: .normal)
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

    @Test func compactUsesOneLineAndATextHeightRankWithoutAnyImageOrIcon() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let row = try imageRow()
        let originalItems = row.entry.items
        let table = try table(in: panel)
        for size in [10.0, 12.0, 24.0, 28.0] {
            panel.update(rows: [row], showPreviews: true, showSizes: true, status: nil,
                         fontSize: size, density: .compact)
            let cell = try laidOutCell(in: panel, table: table)
            let title = try #require(cell.textField)
            let rank = try #require(cell.subviews.first { $0.identifier?.rawValue == "historyRank" })
            let preview = try #require(descendants(NSImageView.self, in: cell).first)
            let titleFrame = title.convert(title.bounds, to: cell)
            #expect(title.font?.pointSize == CGFloat(size))
            #expect(rank.frame.height == titleFrame.height)
            #expect(rank.frame.minY == titleFrame.minY)
            #expect(table.rowHeight == ceil(title.intrinsicContentSize.height) + 4)
            #expect(preview.isHidden)
            #expect(preview.image == nil)
            // Native text fields extend two points beyond their alignment rect.
            #expect((4...8).contains(titleFrame.minX - rank.frame.maxX))
            let visibleFields = descendants(NSTextField.self, in: cell).filter { !$0.isHiddenOrHasHiddenAncestor }
            #expect(visibleFields.count == 2) // title and optional size share one line
            for field in visibleFields {
                let frame = field.convert(field.bounds, to: cell)
                #expect(frame.minY >= 2)
                #expect(frame.maxY <= table.rowHeight - 2)
                #expect(frame.height >= field.intrinsicContentSize.height)
            }
            #expect(cell.toolTip?.contains(row.presentation.typeName) == true)
            #expect(row.entry.items == originalItems)
        }
    }

    @Test func reusedCellRestoresPreviewAndMetadataWhenLeavingCompact() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let row = try imageRow()
        panel.update(rows: [row], showPreviews: true, showSizes: true, status: nil, density: .normal)
        let table = try table(in: panel)
        panel.show(positionAtPointer: false, savedFrame: nil)
        defer { panel.hide() }
        for density in [HistoryDensity.compact, .normal, .large, .compact, .normal] {
            panel.update(rows: [row], showPreviews: true, showSizes: true, status: nil, density: density)
            let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
            cell.layoutSubtreeIfNeeded()
            let preview = try #require(descendants(NSImageView.self, in: cell).first)
            #expect(preview.isHidden == (density == .compact))
            #expect((preview.image == nil) == (density == .compact))
            let visibleFields = descendants(NSTextField.self, in: cell).filter { !$0.isHiddenOrHasHiddenAncestor }
            #expect(visibleFields.count == (density == .compact ? 2 : 3))
        }
    }

    @Test func changingDensityKeepsTheSelectedEntryAndKeyboardPaste() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = [row(text: "first"), row(text: "selected"), row(text: "third")]
        panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil)
        let table = try table(in: panel)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        var pasted: [UUID] = []
        panel.onPaste = { pasted.append($0) }

        for density in [HistoryDensity.large, .compact, .normal, .compact] {
            panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil, density: density)
            #expect(table.selectedRow == 1)
            table.keyDown(with: try enterKey())
        }
        #expect(pasted == Array(repeating: rows[1].id, count: 4))
    }
}
