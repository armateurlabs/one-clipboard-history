import AppKit
import MCMCore

@MainActor
final class HistoryPanelController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onPaste: ((UUID) -> Void)?
    var onSettings: (() -> Void)?
    var onMoved: ((NSRect) -> Void)?
    var onResized: ((NSRect) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onClear: (() -> Void)?

    private let historyPanel: HistoryPanel
    private let table = HistoryTableView()
    private let scrollView = NSScrollView()
    private let statusContainer = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var settingsButton: NSButton?
    private var rows: [HistoryRow] = []
    private var showPreviews = true
    private var showSizes = true
    private var fontSize: CGFloat = 12
    private var compactView = true
    private var rowLayout = HistoryRowLayout(fontSize: 12, compact: true)
    private var rowHeight: CGFloat { rowLayout.height }
    private var positioningWindow = false
    private var didPositionWindow = false
    private var contextEntryID: UUID?
    private var screenObserver: NSObjectProtocol?

    var isVisible: Bool { historyPanel.isVisible && !historyPanel.isMiniaturized }

    init() {
        historyPanel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: historyPanel)
        historyPanel.title = L10n.text("Clipboard History")
        historyPanel.minSize = NSSize(width: 280, height: 280)
        historyPanel.isReleasedWhenClosed = false
        historyPanel.isFloatingPanel = true
        historyPanel.level = .floating
        historyPanel.hidesOnDeactivate = false
        historyPanel.becomesKeyOnlyIfNeeded = false
        historyPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        historyPanel.animationBehavior = .none
        historyPanel.delegate = self
        historyPanel.handleKey = { [weak self] event in self?.handleKey(event) ?? false }
        table.handleKey = { [weak self] event in self?.handleKey(event) ?? false }
        configureContent()
        configureTitlebar()
        refreshLocalization()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.keepWindowOnScreen() }
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(rows newRows: [HistoryRow], showPreviews: Bool, showSizes: Bool, status: String?,
                fontSize: Double = 12, animationsEnabled: Bool = false, compactView: Bool = true) {
        let previousIndex = table.selectedRow
        let previousID = rows.indices.contains(previousIndex) ? rows[previousIndex].entry.id : nil
        rows = newRows
        self.showPreviews = showPreviews
        self.showSizes = showSizes
        let normalizedFontSize = Self.validFontSize(fontSize)
        if self.fontSize != normalizedFontSize || self.compactView != compactView {
            self.fontSize = normalizedFontSize
            self.compactView = compactView
            rowLayout = HistoryRowLayout(fontSize: normalizedFontSize, compact: compactView)
        }
        table.rowHeight = rowHeight
        historyPanel.animationBehavior = animationsEnabled ? .utilityWindow : .none
        historyPanel.alphaValue = 1
        statusLabel.font = .systemFont(ofSize: max(10, self.fontSize - 2))
        emptyLabel.font = .systemFont(ofSize: self.fontSize)
        table.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        if !rows.isEmpty {
            let selection = previousID.flatMap { id in rows.firstIndex { $0.entry.id == id } }
                ?? max(0, min(previousIndex, rows.count - 1))
            table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        }
        statusLabel.stringValue = status ?? ""
        statusContainer.isHidden = status?.isEmpty != false
        statusLabel.toolTip = status
    }

    func refreshLocalization() {
        historyPanel.title = L10n.text("Clipboard History")
        table.setAccessibilityLabel(L10n.text("Clipboard History"))
        emptyLabel.stringValue = L10n.text("History is empty.\nYour next copies will appear here.")
        settingsButton?.setAccessibilityLabel(L10n.text("Settings"))
        settingsButton?.toolTip = L10n.text("Settings (⌘,)")
        table.reloadData()
    }

    func show(positionAtPointer: Bool, savedFrame: NSRect?, pointerQuadrant: PointerQuadrant = .bottomRight) {
        positioningWindow = true
        let screen = screenAtPointer()
        var frame = historyPanel.frame
        if positionAtPointer {
            if let savedFrame, savedFrame.width.isFinite, savedFrame.height.isFinite {
                frame.size = savedFrame.size
            }
            frame = WindowPlacement.frame(around: NSEvent.mouseLocation, size: frame.size,
                quadrant: pointerQuadrant, visibleFrame: screen.visibleFrame, minimumSize: historyPanel.minSize)
        } else if let savedFrame, Self.isUsable(savedFrame) {
            frame = savedFrame
        } else if !didPositionWindow {
            frame.origin = NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.midY - frame.height / 2
            )
        }
        frame = clamped(frame, preferredScreen: positionAtPointer ? screen : nil)
        historyPanel.setFrame(frame, display: false, animate: false)
        historyPanel.alphaValue = 1
        didPositionWindow = true
        if historyPanel.isMiniaturized { historyPanel.deminiaturize(nil) }
        historyPanel.makeKeyAndOrderFront(nil)
        historyPanel.makeFirstResponder(table)
        positioningWindow = false
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }

    func hide() { historyPanel.orderOut(nil) }

    func toggle(positionAtPointer: Bool, savedFrame: NSRect?, pointerQuadrant: PointerQuadrant = .bottomRight) {
        if isVisible { hide() }
        else { show(positionAtPointer: positionAtPointer, savedFrame: savedFrame, pointerQuadrant: pointerQuadrant) }
    }

    private func configureContent() {
        let root = NSView()
        historyPanel.contentView = root
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.allowsTypeSelect = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityLabel(L10n.text("Clipboard History"))
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        table.menu = contextMenu
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        stack.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true

        statusContainer.isHidden = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(statusLabel)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor),
            separator.topAnchor.constraint(equalTo: statusContainer.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -8)
        ])
        stack.addArrangedSubview(statusContainer)
        statusContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40)
        ])
    }

    private func configureTitlebar() {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 28))
        let button = NSButton(
            image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.text("Settings"))!,
            target: self,
            action: #selector(openSettings)
        )
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = L10n.text("Settings (⌘,)")
        button.setAccessibilityLabel(L10n.text("Settings"))
        button.frame = NSRect(x: 1, y: 2, width: 28, height: 24)
        container.addSubview(button)
        settingsButton = button
        accessory.view = container
        historyPanel.addTitlebarAccessoryViewController(accessory)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("historyCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryCellView ?? HistoryCellView()
        cell.identifier = identifier
        cell.configure(row: rows[row], rank: row + 1, showPreview: showPreviews, showSize: showSizes,
                       fontSize: fontSize, layout: rowLayout)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        guard !positioningWindow, didPositionWindow, historyPanel.isVisible else { return }
        let eventType = NSApp.currentEvent?.type
        let mouseMove = NSEvent.pressedMouseButtons & 1 != 0
            || eventType == .leftMouseDragged || eventType == .leftMouseDown || eventType == .leftMouseUp
        guard mouseMove else { return }
        onMoved?(historyPanel.frame)
    }

    func windowDidResize(_ notification: Notification) {
        guard !positioningWindow, didPositionWindow else { return }
        onResized?(historyPanel.frame)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        let selected = rows.indices.contains(clicked) ? clicked : table.selectedRow
        contextEntryID = rows.indices.contains(selected) ? rows[selected].entry.id : nil
        if contextEntryID != nil {
            let delete = NSMenuItem(title: L10n.text("Delete This Entry"), action: #selector(deleteContextEntry), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
            menu.addItem(.separator())
        }
        let clear = NSMenuItem(title: L10n.text("Clear History…"), action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !rows.isEmpty
        menu.addItem(clear)
    }

    @objc private func openSettings() { onSettings?() }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        onPaste?(rows[row].entry.id)
    }

    @objc private func deleteContextEntry() {
        if let contextEntryID { onDelete?(contextEntryID) }
    }

    @objc private func clearHistory() { onClear?() }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), !modifiers.contains(.control),
           event.charactersIgnoringModifiers == "," || (modifiers.contains(.command) && event.keyCode == 43) {
            onSettings?()
            return true
        }
        guard modifiers.intersection([.command, .control]).isEmpty else { return false }
        switch event.keyCode {
        case 53:
            hide()
            return true
        case 36, 76:
            if rows.indices.contains(table.selectedRow) { onPaste?(rows[table.selectedRow].entry.id) }
            return true
        default:
            break
        }
        let digit: Int?
        if let character = event.charactersIgnoringModifiers, character.count == 1,
           let value = Int(character), (1...9).contains(value) {
            digit = value
        } else {
            // Physical keys keep direct selection available on AZERTY layouts.
            digit = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                     83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9][Int(event.keyCode)]
        }
        if let digit {
            if rows.indices.contains(digit - 1) { onPaste?(rows[digit - 1].entry.id) }
            else { NSSound.beep() }
            return true
        }
        return false
    }

    private func screenAtPointer() -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? historyPanel.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func keepWindowOnScreen() {
        guard didPositionWindow else { return }
        positioningWindow = true
        let newFrame = clamped(historyPanel.frame)
        historyPanel.setFrame(newFrame, display: historyPanel.isVisible, animate: false)
        positioningWindow = false
        onResized?(newFrame)
    }

    private func clamped(_ frame: NSRect, preferredScreen: NSScreen? = nil) -> NSRect {
        let screen = preferredScreen ?? NSScreen.screens.max { left, right in
            let leftIntersection = left.visibleFrame.intersection(frame)
            let rightIntersection = right.visibleFrame.intersection(frame)
            return max(0, leftIntersection.width) * max(0, leftIntersection.height)
                < max(0, rightIntersection.width) * max(0, rightIntersection.height)
        } ?? screenAtPointer()
        return WindowPlacement.clamp(frame, to: screen.visibleFrame, minimumSize: historyPanel.minSize)
    }

    private static func isUsable(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func validFontSize(_ value: Double) -> CGFloat {
        value.isFinite ? CGFloat(min(28, max(10, value))) : 12
    }
}

@MainActor
private final class HistoryPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
private final class HistoryTableView: NSTableView {
    var handleKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
private struct HistoryRowLayout {
    static let textSpacing: CGFloat = 2
    let height: CGFloat
    let previewSide: CGFloat
    let numberInset: CGFloat

    init(fontSize: CGFloat, compact: Bool) {
        // Measure native single-line controls once per font/layout change, never
        // per history entry. The same fonts and preview size serve both layouts.
        let title = NSTextField(labelWithString: "Ag")
        title.font = .systemFont(ofSize: fontSize)
        title.usesSingleLineMode = true
        let metadata = NSTextField(labelWithString: "Ag")
        metadata.font = .systemFont(ofSize: max(10, fontSize - 2))
        metadata.usesSingleLineMode = true
        previewSide = min(48, max(40, ceil(fontSize * 1.6)))
        let textHeight = title.intrinsicContentSize.height + metadata.intrinsicContentSize.height + Self.textSpacing
        let fittedHeight = ceil(max(textHeight, previewSide) + 4)
        height = compact ? fittedHeight : max(max(56, ceil(fontSize * 2 + 22)), fittedHeight)
        numberInset = compact ? 4 : 10
    }
}

@MainActor
private final class HistoryCellView: NSTableCellView {
    private let numberPill = NumberPillView()
    private let preview = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private var numberWidth: NSLayoutConstraint!
    private var numberHeight: NSLayoutConstraint!
    private var previewWidth: NSLayoutConstraint!
    private var previewHeight: NSLayoutConstraint!

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            titleLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            detailLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            sizeLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            numberPill.emphasized = selected
        }
    }

    init() {
        super.init(frame: .zero)
        numberPill.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.usesSingleLineMode = true
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.usesSingleLineMode = true
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sizeLabel.font = .systemFont(ofSize: 12)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.usesSingleLineMode = true
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        let metadata = NSStackView(views: [detailLabel, sizeLabel])
        metadata.orientation = .horizontal
        metadata.alignment = .firstBaseline
        metadata.spacing = 8
        let labels = NSStackView(views: [titleLabel, metadata])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = HistoryRowLayout.textSpacing
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(numberPill)
        addSubview(preview)
        addSubview(labels)
        textField = titleLabel
        numberWidth = numberPill.widthAnchor.constraint(equalToConstant: 32)
        numberHeight = numberPill.heightAnchor.constraint(equalToConstant: 46)
        previewWidth = preview.widthAnchor.constraint(equalToConstant: 40)
        previewHeight = preview.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            numberPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            numberPill.centerYAnchor.constraint(equalTo: centerYAnchor),
            numberWidth,
            numberHeight,
            preview.leadingAnchor.constraint(equalTo: numberPill.trailingAnchor, constant: 10),
            preview.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewWidth,
            previewHeight,
            labels.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            metadata.widthAnchor.constraint(equalTo: labels.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(row: HistoryRow, rank: Int, showPreview: Bool, showSize: Bool,
                   fontSize: CGFloat, layout: HistoryRowLayout) {
        numberPill.number = rank
        numberPill.fontSize = fontSize
        numberWidth.constant = max(32, ceil(fontSize * 2))
        numberHeight.constant = layout.height - layout.numberInset
        previewWidth.constant = layout.previewSide
        previewHeight.constant = layout.previewSide
        titleLabel.font = .systemFont(ofSize: fontSize)
        detailLabel.font = .systemFont(ofSize: max(10, fontSize - 2))
        sizeLabel.font = detailLabel.font
        titleLabel.stringValue = row.presentation.title
        var details = [row.presentation.typeName]
        let comment = row.presentation.detail
        if !comment.isEmpty, comment != row.presentation.typeName { details.append(comment) }
        if let source = row.entry.sourceAppName, !details.joined().localizedCaseInsensitiveContains(source) {
            details.append(L10n.format("Copied from %@", source))
        }
        let incomplete = L10n.text("Incomplete Capture")
        if !row.entry.isComplete, !details.joined().localizedCaseInsensitiveContains(incomplete) { details.append(incomplete) }
        detailLabel.stringValue = details.filter { !$0.isEmpty }.joined(separator: " · ")
        sizeLabel.stringValue = row.presentation.displayByteCount < 0 ? "…"
            : ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: L10n.currentLocale).format(row.presentation.displayByteCount)
        sizeLabel.isHidden = !showSize
        toolTip = "\(row.presentation.title)\n\(detailLabel.stringValue)\(showSize ? " · " + sizeLabel.stringValue : "")"
        if showPreview, let data = row.presentation.thumbnailData, let image = NSImage(data: data) {
            preview.image = image
            preview.contentTintColor = nil
        } else {
            let symbol = row.presentation.fileURLs.isEmpty ? "doc" : "doc.fill"
            preview.image = NSImage(systemSymbolName: symbol, accessibilityDescription: row.presentation.typeName)?
                .withSymbolConfiguration(.init(pointSize: 30, weight: .regular))
            preview.contentTintColor = .secondaryLabelColor
        }
        setAccessibilityLabel("\(rank), \(row.presentation.title), \(detailLabel.stringValue)")
    }
}

@MainActor
private final class NumberPillView: NSView {
    var number = 1 { didSet { needsDisplay = true } }
    var emphasized = false { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 12 { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = emphasized ? NSColor.white.withAlphaComponent(0.14) : NSColor.quaternaryLabelColor
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor
        ]
        let value = String(number) as NSString
        let size = value.size(withAttributes: attributes)
        value.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
