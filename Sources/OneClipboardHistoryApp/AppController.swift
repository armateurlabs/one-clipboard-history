import AppKit
import Carbon
import OneClipboardHistoryCore
import SwiftUI

struct HistoryRow: Identifiable, Sendable {
    let entry: ClipboardEntry
    let presentation: ClipboardPresentation
    var id: UUID { entry.id }
}

@MainActor
final class AppController {
    let settings: AppSettings
    let loginItem: LoginItemController
    let panel = HistoryPanelController()
    private let pasteboard: PasteboardService
    private let repository: HistoryRepository
    private let hotkey = GlobalHotkey()
    private let demo: Bool
    private let previewDefaultsDomain: String?
    private let previewDirectory: URL?
    private let information = AppInformationController()
    private var entries: [ClipboardEntry] = []
    private var rows: [HistoryRow] = []
    private var presentationCache: [UUID: ClipboardPresentation] = [:]
    private var cacheIncludesPreviews = true
    private var statusMessage: String?
    private var statusError: (any Error)?
    private var appliedLanguage: AppLanguage = .system
    private var operation: Task<Void, Never>?
    private var pasteOperation: Task<Void, Never>?
    private var presentationWorkers: [UUID: Task<Void, Never>] = [:]
    private var presentationGeneration = 0
    private var settingsWindow: NSWindowController?
    private var statusItem: NSStatusItem?
    private var isRecordingShortcut = false
    private var pasteTarget: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var applicationActivationObserver: NSObjectProtocol?
    private var capturePermissionRequestsAllowed = false
    private var pasteInProgress = false
    private var shuttingDown = false
    private var operationGeneration = 0
    private var appliedConfiguration: (count: Int, bytes: Int64, persistent: Bool)?

    init(demo: Bool, arguments: [String] = ProcessInfo.processInfo.arguments) throws {
        self.demo = demo
        let previewDomain = demo ? "com.armateurlabs.oneclipboardhistory.preview.\(UUID().uuidString)" : nil
        previewDefaultsDomain = previewDomain
        settings = AppSettings(defaults: previewDomain.map {
            PreviewConfiguration(arguments: arguments).makeDefaults(domain: $0)
        } ?? .standard)
        AppAppearance.apply(settings.appearanceMode)
        L10n.configure(settings.language)
        appliedLanguage = settings.language
        loginItem = demo ? .preview() : LoginItemController()
        let directory = demo
            ? FileManager.default.temporaryDirectory.appendingPathComponent("one-clipboard-history-preview-\(UUID().uuidString)", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("mcm/History", isDirectory: true)
        previewDirectory = demo ? directory : nil
        repository = try HistoryRepository(directory: directory,
            configuration: .init(maxCount: settings.historyLimit, maxBytes: Int64(settings.budgetMegabytes) * 1_048_576),
            persistenceEnabled: !demo && settings.persistenceEnabled)
        pasteboard = PasteboardService(pasteboardName: previewDomain)
        appliedConfiguration = (settings.historyLimit, Int64(settings.budgetMegabytes) * 1_048_576, !demo && settings.persistenceEnabled)
    }

    func start() {
        panel.refreshLocalization()
        render()
        panel.onPaste = { [weak self] in self?.paste(id: $0) }
        panel.onSettings = { [weak self] in self?.showSettings() }
        panel.onMoved = { [weak self] frame in
            guard let self else { return }
            settings.savedFrame = frame
            if settings.positionAtPointer { settings.positionAtPointer = false }
        }
        panel.onResized = { [weak self] frame in self?.settings.savedFrame = frame }
        panel.onDelete = { [weak self] in self?.remove(id: $0) }
        panel.onClear = { [weak self] in self?.confirmClear() }
        settings.onChange = { [weak self] in self?.settingsDidChange() }
        settings.onShortcutRecordingChange = { [weak self] recording in
            guard let self else { return }
            isRecordingShortcut = recording
            if recording { hotkey.suspend() }
            else { configureHotkey(force: true) }
        }
        hotkey.onPressed = { [weak self] in
            guard let self, !isRecordingShortcut else { return }
            toggle()
        }
        configureHotkey()
        buildMenu()
        lastExternalApplication = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                if application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self?.lastExternalApplication = application
                }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in
            self?.restartCapture()
            self?.configureHotkey(force: true)
        } }
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in
            self?.loginItem.refresh()
            self?.configureHotkey(force: true)
        } }
        enqueue { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await repository.load()
                await refresh(loaded)
                let warnings = await repository.warnings()
                if let warning = warnings.first { setStatus(warning) }
                if demo {
                    await seedDemo()
                    show()
                } else {
                    restartCapture()
                }
            } catch {
                setStatus("Could not load history: %@", error: error)
                restartCapture()
            }
        }
    }

    func stop() {
        pasteboard.stop()
        hotkey.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let applicationActivationObserver { NotificationCenter.default.removeObserver(applicationActivationObserver) }
        if let previewDefaultsDomain { UserDefaults.standard.removePersistentDomain(forName: previewDefaultsDomain) }
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
    }

    func shutdown() async {
        shuttingDown = true
        hotkey.stop()
        await pasteboard.stopAndWait()
        await pasteOperation?.value
        // Capture callbacks already delivered to the main actor must join the drain.
        await Task.yield()
        while true {
            let generation = operationGeneration
            await operation?.value
            await Task.yield()
            if generation == operationGeneration { break }
        }
    }

    private func restartCapture() {
        guard !demo, !shuttingDown else { return }
        pasteboard.stop()
        pasteboard.start(onCapture: { [weak self] entry in
            Task { @MainActor [weak self] in self?.receive(entry) }
        }, onStatus: { [weak self] message in
            Task { @MainActor [weak self] in self?.setStatus(message) }
        }, allowPermissionPrompts: capturePermissionRequestsAllowed)
    }

    private func receive(_ entry: ClipboardEntry) {
        enqueue { [weak self] in
            guard let self else { return }
            do {
                let update = try await repository.insert(entry)
                await refresh(update.entries)
                if let reason = update.rejectedReason { setStatus(reason) }
                else if !entry.isComplete { setStatus("Incomplete capture: some formats could not be preserved.") }
                else { setStatus(nil) }
            } catch {
                await refresh(await repository.currentEntries())
                setStatus("History is in memory; saving failed: %@", error: error)
            }
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        operationGeneration += 1
        operation = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func refresh(_ newEntries: [ClipboardEntry]) async {
        let previousBookmarks = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.fileBookmarks) })
        for entry in newEntries where previousBookmarks[entry.id].map({ $0 != entry.fileBookmarks }) == true {
            // An exact recopy keeps its identity, but can carry a fresh Finder
            // grant. Do not retain an earlier unavailable-file presentation.
            presentationCache.removeValue(forKey: entry.id)
            presentationWorkers.removeValue(forKey: entry.id)?.cancel()
        }
        entries = newEntries
        let includeThumbnail = settings.showPreviews && settings.historyDensity != .compact
        if cacheIncludesPreviews != includeThumbnail {
            presentationCache.removeAll()
            for worker in presentationWorkers.values { worker.cancel() }
            presentationWorkers.removeAll()
            presentationGeneration += 1
            cacheIncludesPreviews = includeThumbnail
        }
        let live = Set(newEntries.map(\.id))
        presentationCache = presentationCache.filter { live.contains($0.key) }
        for id in presentationWorkers.keys.filter({ !live.contains($0) }) {
            presentationWorkers.removeValue(forKey: id)?.cancel()
        }
        rebuildRows()
        // Saved file previews can also require a macOS privacy prompt. During
        // background startup, use display-only placeholders until the user opens
        // the history; no file metadata or image contents are read here yet.
        guard capturePermissionRequestsAllowed else { return }
        let missing = newEntries.filter { presentationCache[$0.id] == nil && presentationWorkers[$0.id] == nil }
        let generation = presentationGeneration
        for entry in missing {
            presentationWorkers[entry.id] = Task { @MainActor [weak self] in
                let presentation = await Task.detached(priority: .userInitiated) {
                    ClipboardPresentation.make(for: entry, includeThumbnail: includeThumbnail)
                }.value
                guard !Task.isCancelled, let self, generation == presentationGeneration,
                      entries.contains(where: { $0.id == entry.id }) else { return }
                presentationWorkers[entry.id] = nil
                presentationCache[entry.id] = presentation
                rebuildRows()
                if let bookmarks = presentation.refreshedFileBookmarks, !bookmarks.isEmpty {
                    enqueue { [weak self] in
                        guard let self, !shuttingDown else { return }
                        do {
                            let updated = try await repository.updateFileBookmarks(id: entry.id, bookmarks: bookmarks)
                            if let value = updated.first(where: { $0.id == entry.id }),
                               let index = entries.firstIndex(where: { $0.id == entry.id }) {
                                entries[index] = value
                                // Keep the completed presentation in the cache:
                                // renewing a credential must not restart enrichment.
                                rebuildRows()
                            }
                        } catch {
                            if let value = await repository.currentEntries().first(where: { $0.id == entry.id }),
                               let index = entries.firstIndex(where: { $0.id == entry.id }) {
                                entries[index] = value
                                rebuildRows()
                            }
                            setStatus("History is in memory; saving failed: %@", error: error)
                        }
                    }
                }
            }
        }
    }

    private func rebuildRows() {
        rows = entries.map { entry in
            HistoryRow(entry: entry, presentation: presentationCache[entry.id] ?? ClipboardPresentation.placeholder(for: entry))
        }
        render()
    }

    private func render() {
        let status = statusMessage.map { key in
            statusError.map { L10n.format(key, $0.localizedDescription) } ?? L10n.text(key)
        }
        panel.update(rows: rows, showPreviews: settings.showPreviews, showSizes: settings.showSizes,
                     status: status, fontSize: settings.historyFontSize, animationsEnabled: settings.animationsEnabled,
                     density: settings.historyDensity)
    }

    private func setStatus(_ message: String?, error: (any Error)? = nil) {
        statusMessage = message
        statusError = error
        render()
    }

    func toggle() {
        guard !shuttingDown else { return }
        if panel.isVisible { panel.hide() } else { show() }
    }

    func show() {
        let needsPresentationEnrichment = !capturePermissionRequestsAllowed
        capturePermissionRequestsAllowed = true
        pasteboard.allowPermissionRequests()
        let current = NSWorkspace.shared.frontmostApplication
        pasteTarget = current?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApplication : current
        let start = ContinuousClock.now
        panel.show(positionAtPointer: settings.positionAtPointer, savedFrame: settings.savedFrame, pointerQuadrant: settings.pointerQuadrant)
        if needsPresentationEnrichment {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await refresh(entries)
            }
        }
        let duration = start.duration(to: .now)
        // This records timing only: never log clipboard contents or source metadata.
        if ProcessInfo.processInfo.arguments.contains("--measure") {
            print("panel_open_duration=\(duration)")
        }
    }

    private func paste(id: UUID) {
        guard !shuttingDown, !pasteInProgress, let entry = entries.first(where: { $0.id == id }) else { return }
        guard entry.isComplete else {
            setStatus("Paste stopped: this entry was not captured completely.")
            return
        }
        pasteInProgress = true
        let target = pasteTarget
        pasteOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { pasteInProgress = false }
            guard !Task.isCancelled, !shuttingDown else { return }
            var allowSourceContextLoss = false
            if entry.requiresExcelSourceContext {
                do {
                    let preservesContext = try await pasteboard.canPreserveNativeContext(for: entry)
                    guard !Task.isCancelled, !shuttingDown else { return }
                    if !preservesContext {
                        // Ask before switching focus or changing the clipboard.
                        // Exact bytes cannot recreate Excel's private live OLE
                        // context; a normal-looking paste can flatten formulas.
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = L10n.text("Excel formulas may paste as values")
                        alert.informativeText = L10n.text("This Excel copy depends on its original clipboard context. The saved data is intact, but restoring it may paste values instead of formulas.")
                        alert.addButton(withTitle: L10n.text("Cancel"))
                        alert.addButton(withTitle: L10n.text("Restore saved formats"))
                        guard alert.runModal() == .alertSecondButtonReturn else { return }
                        guard !Task.isCancelled, !shuttingDown else { return }
                        allowSourceContextLoss = true
                    }
                } catch {
                    setStatus("Could not paste: %@", error: error)
                    return
                }
            }
            let canPaste = !demo && CGPreflightPostEventAccess() && target?.isTerminated == false
            if !canPaste {
                guard await copy(entry, allowSourceContextLoss: allowSourceContextLoss) else { return }
                guard !Task.isCancelled, !shuttingDown else { return }
                setStatus(demo ? "Preview mode: copied to a private clipboard."
                    : "Entry copied. Allow automatic paste in Settings or paste with ⌘V.")
                if !demo, let target, !target.isTerminated {
                    if settings.hideAfterPasting { panel.hide() }
                    panel.window?.resignKey()
                    target.activate(options: [])
                }
                await promoteCopiedEntry(id: id)
                return
            }
            guard let target else { return }
            if settings.hideAfterPasting { panel.hide() }
            panel.window?.resignKey()
            target.activate(options: [])
            var ready = false
            for _ in 0..<25 {
                guard !Task.isCancelled, !shuttingDown else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                   panel.window?.isKeyWindow != true {
                    ready = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled, !shuttingDown else { return }
            guard ready else {
                if await copy(entry, allowSourceContextLoss: allowSourceContextLoss) {
                    guard !Task.isCancelled, !shuttingDown else { return }
                    setStatus("Entry copied. Could not return to the previous app; paste with ⌘V.")
                    await promoteCopiedEntry(id: id)
                }
                guard !Task.isCancelled, !shuttingDown else { return }
                panel.show(positionAtPointer: settings.positionAtPointer, savedFrame: settings.savedFrame, pointerQuadrant: settings.pointerQuadrant)
                return
            }
            // Let the target's focus transition settle before posting the shortcut.
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, !shuttingDown else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                setStatus("Paste stopped: the target app changed.")
                panel.show(positionAtPointer: settings.positionAtPointer, savedFrame: settings.savedFrame, pointerQuadrant: settings.pointerQuadrant)
                return
            }
            // Restore only after activation has settled. No disk or preview work may
            // run between this final clipboard write and the synthesized paste.
            guard await copy(entry, allowSourceContextLoss: allowSourceContextLoss) else {
                guard !Task.isCancelled, !shuttingDown else { return }
                panel.show(positionAtPointer: settings.positionAtPointer, savedFrame: settings.savedFrame, pointerQuadrant: settings.pointerQuadrant)
                return
            }
            guard !Task.isCancelled, !shuttingDown else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  CGPreflightPostEventAccess() else {
                setStatus("Entry copied; paste with ⌘V.")
                panel.show(positionAtPointer: settings.positionAtPointer, savedFrame: settings.savedFrame, pointerQuadrant: settings.pointerQuadrant)
                await promoteCopiedEntry(id: id)
                return
            }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            setStatus(nil)
            await promoteCopiedEntry(id: id)
        }
    }

    private func copy(_ entry: ClipboardEntry, allowSourceContextLoss: Bool = false) async -> Bool {
        do { try await pasteboard.write(entry, allowSourceContextLoss: allowSourceContextLoss); return true }
        catch { setStatus("Could not paste: %@", error: error); return false }
    }

    private func promoteCopiedEntry(id: UUID) async {
        do {
            let promoted = try await repository.promote(id: id)
            guard !Task.isCancelled, !shuttingDown else { return }
            await refresh(promoted)
        }
        catch {
            let current = await repository.currentEntries()
            guard !Task.isCancelled, !shuttingDown else { return }
            await refresh(current)
            setStatus("Entry copied; could not save history: %@", error: error)
        }
    }

    private func settingsDidChange() {
        guard !shuttingDown else { return }
        AppAppearance.apply(settings.appearanceMode)
        if appliedLanguage != settings.language {
            L10n.configure(settings.language)
            appliedLanguage = settings.language
            loginItem.refresh()
            presentationCache.removeAll()
            for worker in presentationWorkers.values { worker.cancel() }
            presentationWorkers.removeAll()
            presentationGeneration += 1
            panel.refreshLocalization()
            settingsWindow?.window?.title = L10n.text("One Clipboard History Settings")
            information.refreshLocalization()
            buildMenu()
            rebuildRows()
        }
        render()
        settingsWindow?.window?.animationBehavior = settings.animationsEnabled ? .default : .none
        configureHotkey()
        let config = HistoryConfiguration(maxCount: max(1, settings.historyLimit),
                                           maxBytes: Int64(max(1, min(settings.budgetMegabytes, 1_048_576))) * 1_048_576)
        let persistent = !demo && settings.persistenceEnabled
        let previous = appliedConfiguration
        let configurationChanged = previous?.count != config.maxCount || previous?.bytes != config.maxBytes || previous?.persistent != persistent
        appliedConfiguration = (config.maxCount, config.maxBytes, persistent)
        enqueue { [weak self] in
            guard let self else { return }
            guard configurationChanged else { await refresh(entries); return }
            do { await refresh(try await repository.configure(config, persistenceEnabled: persistent)) }
            catch {
                await refresh(await repository.currentEntries())
                setStatus("Could not change history storage: %@", error: error)
            }
        }
    }

    private func configureHotkey(force: Bool = false) {
        // The screenshot preview must never compete with the installed app.
        guard !demo, !shuttingDown, !isRecordingShortcut else { return }
        if hotkey.register(settings.shortcut, force: force) {
            settings.shortcutError = nil
            if statusMessage == "Shortcut unavailable: choose another one in Settings." { setStatus(nil) }
        } else {
            settings.shortcutError = !hotkey.hasActiveShortcut
                ? "Shortcut unavailable. Choose a different shortcut."
                : "Shortcut unavailable. The previous shortcut remains active."
            setStatus("Shortcut unavailable: choose another one in Settings.")
        }
    }

    func showSettings() {
        panel.hide()
        loginItem.refresh()
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, loginItem: loginItem, onAccessibility: { [weak self] in self?.requestAccessibility() },
                onPasteboardSettings: { [weak self] in
                    guard self?.demo == false else { return }
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
                        NSWorkspace.shared.open(url)
                    }
                }, onClear: { [weak self] in self?.confirmClear() },
                onImportHistory: AppInformation.isStoreBuild && !demo ? { [weak self] in self?.importLegacyHistory() } : nil)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = L10n.text("One Clipboard History Settings")
            window.styleMask = [.titled, .closable]
            window.animationBehavior = settings.animationsEnabled ? .default : .none
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = NSWindowController(window: window)
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        // Accessory apps need a visible regular window before activation.
        NSApp.activate()
    }

    private func requestAccessibility() {
        guard !demo else { return }
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func importLegacyHistory() {
        guard AppInformation.isStoreBuild, !demo, !shuttingDown else { return }
        let chooser = NSOpenPanel()
        chooser.title = L10n.text("Import Existing History")
        chooser.message = L10n.text("Choose the mcm History folder containing history.sqlite3 and blobs. Your existing copies and the source backup will be kept.")
        chooser.prompt = L10n.text("Import")
        chooser.canChooseFiles = false
        chooser.canChooseDirectories = true
        chooser.canCreateDirectories = false
        chooser.allowsMultipleSelection = false
        guard chooser.runModal() == .OK, let directory = chooser.url else { return }
        // NSOpenPanel has already started an implicit security scope. Keep its
        // lease alive through queued import, including cancellation before run.
        let selection = OpenPanelDirectoryAccess(url: directory)
        enqueue { [weak self] in
            defer { withExtendedLifetime(selection) {} }
            guard let self, !shuttingDown else { return }
            do {
                let result = try await repository.importLegacyHistory(from: selection.url)
                await refresh(result.entries)
                let alert = NSAlert()
                alert.messageText = L10n.text("History Imported")
                alert.informativeText = L10n.format("Imported %ld entries. %ld identical copies were skipped.",
                                                  result.importedCount, result.duplicateCount)
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.text("Could not import history.")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func remove(id: UUID) {
        enqueue { [weak self] in
            guard let self else { return }
            do { await refresh(try await repository.remove(id: id)) }
            catch { setStatus("Could not remove entry: %@", error: error) }
        }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = L10n.text("Clear history?")
        alert.informativeText = L10n.text("One Clipboard History entries will be removed. Original files will be kept.")
        alert.addButton(withTitle: L10n.text("Clear"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        enqueue { [weak self] in
            guard let self else { return }
            do { await refresh(try await repository.clear()); setStatus(nil) }
            catch { setStatus("Could not clear history: %@", error: error) }
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: AppInformation.name)
        applicationMenu.addItem(withTitle: L10n.text("About One Clipboard History"), action: #selector(menuAbout), keyEquivalent: "").target = self
        applicationMenu.addItem(withTitle: L10n.text("MIT License"), action: #selector(menuLicense), keyEquivalent: "").target = self
        applicationMenu.addItem(withTitle: L10n.text("Privacy Policy"), action: #selector(menuPrivacy), keyEquivalent: "").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: L10n.text("Settings…"), action: #selector(menuSettings), keyEquivalent: ",").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: L10n.text("Hide One Clipboard History"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(withTitle: L10n.text("Quit One Clipboard History"), action: #selector(menuQuit), keyEquivalent: "q").target = self
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.text("Edit"))
        editMenu.addItem(withTitle: L10n.text("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: AppInformation.name)
        item.button?.setAccessibilityLabel(AppInformation.name)
        item.button?.toolTip = AppInformation.name
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.text("Show History"), action: #selector(menuShow), keyEquivalent: "").target = self
        menu.addItem(withTitle: L10n.text("Settings…"), action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("About One Clipboard History"), action: #selector(menuAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: L10n.text("MIT License"), action: #selector(menuLicense), keyEquivalent: "").target = self
        menu.addItem(withTitle: L10n.text("Privacy Policy"), action: #selector(menuPrivacy), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("Quit One Clipboard History"), action: #selector(menuQuit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func menuShow() { toggle() }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuAbout() { panel.hide(); information.showAbout() }
    @objc private func menuLicense() { panel.hide(); information.show(.license) }
    @objc private func menuPrivacy() { panel.hide(); information.show(.privacy) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func seedDemo() async {
        guard demo, let previewDirectory else { return }
        do {
            for entry in try DemoFixtures.entries(in: previewDirectory.appendingPathComponent("Samples")).reversed() {
                let update = try await repository.insert(entry)
                await refresh(update.entries)
            }
        } catch {
            setStatus("Could not load preview examples: %@", error: error)
        }
    }
}
