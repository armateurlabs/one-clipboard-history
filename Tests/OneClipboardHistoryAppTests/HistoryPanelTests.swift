import AppKit
import OneClipboardHistoryCore
import Testing
@testable import OneClipboardHistoryApp

@Suite("History keyboard interactions", .serialized)
@MainActor
struct HistoryPanelTests {
    private func makeRows(_ count: Int) -> [HistoryRow] {
        (0..<count).map { index in
            let entry = ClipboardEntry(items: [.init(representations: [
                .init(type: "public.utf8-plain-text", data: Data("entry \(index + 1)".utf8))
            ])])
            return HistoryRow(entry: entry, presentation: .make(for: entry, includeThumbnail: false))
        }
    }

    private func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap { textFields(in: $0) }
    }

    private func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ))
    }

    @Test func digitsAndAzertyKeysPasteExactlyTheDisplayedRanks() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = makeRows(12)
        panel.update(rows: rows, showPreviews: false, showSizes: true, status: nil)
        let table = try #require(findTable(in: panel.window?.contentView))
        var pasted: [UUID] = []
        panel.onPaste = { pasted.append($0) }

        table.keyDown(with: try key(18, characters: "1"))
        table.keyDown(with: try key(18, characters: "&"))
        table.keyDown(with: try key(23, characters: "5"))
        table.keyDown(with: try key(92, characters: "9", modifiers: .numericPad))

        #expect(pasted == [rows[0].id, rows[0].id, rows[4].id, rows[8].id])
        #expect(table.numberOfRows == 12)
        #expect(panel.isVisible == false)
    }

    @Test func enterKeepsTheSelectedIdentityAfterANewCopyChangesRanks() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = makeRows(3)
        panel.update(rows: rows, showPreviews: false, showSizes: true, status: nil)
        let table = try #require(findTable(in: panel.window?.contentView))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let newest = try #require(makeRows(1).first)
        panel.update(rows: [newest] + rows, showPreviews: true, showSizes: false, status: nil)
        var pasted: UUID?
        panel.onPaste = { pasted = $0 }

        table.keyDown(with: try key(36, characters: "\r"))

        #expect(table.selectedRow == 2)
        #expect(pasted == rows[1].id)
    }

    @Test func digitSelectionTracksCurrentRankAfterReordering() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = makeRows(3)
        panel.update(rows: rows, showPreviews: false, showSizes: true, status: nil)
        panel.update(rows: [rows[2], rows[0], rows[1]], showPreviews: false, showSizes: true, status: nil)
        let table = try #require(findTable(in: panel.window?.contentView))
        var pasted: UUID?
        panel.onPaste = { pasted = $0 }

        table.keyDown(with: try key(18, characters: "1"))

        #expect(pasted == rows[2].id)
    }

    @Test func emptyHistoryAndRemovalCannotPasteAStaleSelection() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = makeRows(2)
        panel.update(rows: rows, showPreviews: false, showSizes: true, status: nil)
        let table = try #require(findTable(in: panel.window?.contentView))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        var pasted: [UUID] = []
        panel.onPaste = { pasted.append($0) }

        panel.update(rows: [rows[0]], showPreviews: false, showSizes: true, status: nil)
        table.keyDown(with: try key(36, characters: "\r"))
        panel.update(rows: [], showPreviews: false, showSizes: false, status: nil)
        table.keyDown(with: try key(36, characters: "\r"))

        #expect(pasted == [rows[0].id])
        #expect(table.numberOfRows == 0)
    }

    @Test func commandAndControlDigitsNeverTriggerImmediatePaste() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        panel.update(rows: makeRows(3), showPreviews: false, showSizes: true, status: nil)
        let table = try #require(findTable(in: panel.window?.contentView))
        var pasted = false
        panel.onPaste = { _ in pasted = true }

        table.keyDown(with: try key(18, characters: "1", modifiers: .command))
        table.keyDown(with: try key(18, characters: "1", modifiers: .control))

        #expect(!pasted)
    }

    @Test func commandCommaOpensSettingsWithoutPasting() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        panel.update(rows: makeRows(1), showPreviews: false, showSizes: true, status: nil)
        let table = try #require(findTable(in: panel.window?.contentView))
        var openedSettings = 0
        var pasted = false
        panel.onSettings = { openedSettings += 1 }
        panel.onPaste = { _ in pasted = true }

        table.keyDown(with: try key(43, characters: ",", modifiers: .command))

        #expect(openedSettings == 1)
        #expect(!pasted)
    }

    @Test func fontSizeUpdatesVisibleTextAndRowGeometryTogether() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = makeRows(2)
        panel.update(rows: rows, showPreviews: false, showSizes: true, status: nil, fontSize: 24, compactView: false)
        let table = try #require(findTable(in: panel.window?.contentView))
        let cell = try #require(panel.tableView(table, viewFor: table.tableColumns.first, row: 0) as? NSTableCellView)
        let fonts = textFields(in: cell).compactMap { $0.font?.pointSize }

        #expect(table.rowHeight == 70)
        #expect(panel.tableView(table, heightOfRow: 0) == 70)
        #expect(cell.textField?.font?.pointSize == 24)
        #expect(fonts.contains(22))
        #expect(fonts.allSatisfy { $0 == 24 || $0 == 22 })

        panel.update(rows: rows, showPreviews: false, showSizes: true, status: nil, fontSize: 10, compactView: false)
        let small = try #require(panel.tableView(table, viewFor: table.tableColumns.first, row: 0) as? NSTableCellView)
        #expect(table.rowHeight == 56)
        #expect(small.textField?.font?.pointSize == 10)
        #expect(textFields(in: small).allSatisfy { $0.font?.pointSize == 10 })
    }

    @Test func invalidFontSizesStayFiniteAndBounded() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = makeRows(1)
        let table = try #require(findTable(in: panel.window?.contentView))
        for (requested, expected) in [(Double.nan, 12.0), (.infinity, 12.0), (-20, 10), (1000, 28)] {
            panel.update(rows: rows, showPreviews: false, showSizes: true, status: nil, fontSize: requested)
            let cell = try #require(panel.tableView(table, viewFor: table.tableColumns.first, row: 0) as? NSTableCellView)
            #expect(cell.textField?.font?.pointSize == CGFloat(expected))
            #expect(table.rowHeight.isFinite)
            #expect(table.rowHeight >= 44 && table.rowHeight <= 78)
        }
    }

    @Test func animationIsInstantByDefaultAndCanBeEnabledThenDisabled() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        #expect(panel.window?.animationBehavior == NSWindow.AnimationBehavior.none)
        panel.update(rows: makeRows(1), showPreviews: false, showSizes: true, status: nil,
                     animationsEnabled: true)
        #expect(panel.window?.animationBehavior == NSWindow.AnimationBehavior.utilityWindow)
        panel.window?.alphaValue = 0.4
        panel.update(rows: makeRows(1), showPreviews: false, showSizes: true, status: nil,
                     animationsEnabled: false)
        #expect(panel.window?.animationBehavior == NSWindow.AnimationBehavior.none)
        #expect(panel.window?.alphaValue == 1)
    }

    @Test func defaultFontIsTwelvePointsAndWindowCanBeNarrower() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        panel.update(rows: makeRows(1), showPreviews: true, showSizes: true, status: nil)
        let window = try #require(panel.window)
        #expect(window.minSize.width == 280)
        window.setFrame(.init(x: 100, y: 100, width: 280, height: 640), display: false, animate: false)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.frame.width == 280)
        let table = try #require(findTable(in: window.contentView))
        let cell = try #require(panel.tableView(table, viewFor: table.tableColumns.first, row: 0) as? NSTableCellView)
        #expect(cell.textField?.font?.pointSize == 12)
    }
}
