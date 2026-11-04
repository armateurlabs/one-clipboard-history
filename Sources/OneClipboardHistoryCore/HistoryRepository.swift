import Foundation

/// The only owner of the ordered history and its optional on-disk store.
public actor HistoryRepository {
    private let directory: URL
    private var configuration: HistoryConfiguration
    private var persistenceEnabled: Bool
    private var storage: HistoryPersistence?
    private var entries: [ClipboardEntry] = []
    private var didLoad = false
    private var pendingWarnings: [String] = []

    public init(
        directory: URL, configuration: HistoryConfiguration = .init(),
        persistenceEnabled: Bool = false
    ) throws {
        self.directory = directory
        self.configuration = HistoryConfiguration(maxCount: configuration.maxCount, maxBytes: configuration.maxBytes)
        self.persistenceEnabled = persistenceEnabled
    }

    @discardableResult
    public func load() throws -> [ClipboardEntry] {
        guard !didLoad else { return entries }
        didLoad = true
        guard persistenceEnabled else {
            // An old saved history must not survive an explicitly disabled preference.
            try HistoryPersistence.removeSavedHistory(at: directory)
            return entries
        }
        do {
            let store = try HistoryPersistence(directory: directory)
            let result = try store.load()
            entries = result.entries
            pendingWarnings.append(contentsOf: result.warnings)
            storage = store
            let previousCount = entries.count
            trim()
            if previousCount != entries.count {
                pendingWarnings.append(L10n.text("Saved history was trimmed to the configured history limits."))
            }
            // Removes skipped records and orphaned blobs only after a successful commit.
            try store.save(entries)
        } catch {
            pendingWarnings.append(L10n.format("Saved history could not be fully loaded: %@", error.localizedDescription))
        }
        return entries
    }

    public func currentEntries() -> [ClipboardEntry] { entries }

    /// Returns and clears recoverable load warnings without including clipboard contents.
    public func warnings() -> [String] {
        if let storage { pendingWarnings.append(contentsOf: storage.drainMaintenanceWarnings()) }
        defer { pendingWarnings.removeAll() }
        return pendingWarnings
    }

    public func insert(_ entry: ClipboardEntry) throws -> HistoryUpdate {
        _ = try load()
        guard entry.byteCount <= configuration.maxBytes else {
            return HistoryUpdate(
                entries: entries,
                rejectedReason: L10n.text("Clipboard entry exceeds the configured data budget; no formats were discarded.")
            )
        }
        if let index = entries.firstIndex(where: { $0.hasIdenticalContent(to: entry) }) {
            let existing = entries.remove(at: index)
            let bookmarks = Self.mergeBookmarks(existing.fileBookmarks, entry.fileBookmarks)
            entries.insert(bookmarks == existing.fileBookmarks ? existing : existing.withFileBookmarks(bookmarks), at: 0)
        } else {
            // IDs are application-owned, but replacing a reused ID also preserves database uniqueness.
            entries.removeAll { $0.id == entry.id }
            entries.insert(entry, at: 0)
        }
        trim()
        try save()
        return HistoryUpdate(entries: entries)
    }

    public func promote(id: UUID) throws -> [ClipboardEntry] {
        _ = try load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return entries }
        entries.insert(entries.remove(at: index), at: 0)
        try save()
        return entries
    }

    public func configure(
        _ config: HistoryConfiguration, persistenceEnabled enabled: Bool
    ) throws -> [ClipboardEntry] {
        _ = try load()
        configuration = HistoryConfiguration(maxCount: config.maxCount, maxBytes: config.maxBytes)
        trim()
        persistenceEnabled = enabled
        if enabled {
            try save()
        } else {
            storage = nil // Close SQLite before deleting it, including any journal.
            try HistoryPersistence.removeSavedHistory(at: directory)
        }
        return entries
    }

    public func remove(id: UUID) throws -> [ClipboardEntry] {
        _ = try load()
        entries.removeAll { $0.id == id }
        try save()
        return entries
    }

    public func clear() throws -> [ClipboardEntry] {
        _ = try load()
        entries.removeAll()
        try save()
        return entries
    }

    /// Renew app-owned credentials without changing the copied bytes, rank or identity.
    public func updateFileBookmarks(id: UUID, bookmarks: [ClipboardFileBookmark]) throws -> [ClipboardEntry] {
        _ = try load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return entries }
        let allowed = ClipboardPresentation.fileURLs(for: entries[index])
        let filtered = bookmarks.filter { bookmark in
            allowed.contains { FileAccessManager.sameLocation($0, bookmark.originalURL) }
        }
        let merged = Self.mergeBookmarks(entries[index].fileBookmarks, filtered)
        guard merged != entries[index].fileBookmarks else { return entries }
        entries[index] = entries[index].withFileBookmarks(merged)
        try save()
        return entries
    }

    /// Explicit import only. Existing entries win and no entry is evicted to
    /// accommodate an import. Validation and persistence complete before memory changes.
    public func importLegacyHistory(from authorizedDirectory: URL) throws -> LegacyHistoryImportResult {
        _ = try load()
        guard directory.standardizedFileURL.resolvingSymlinksInPath()
            != authorizedDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
            throw LegacyHistoryImportError.invalidDirectory
        }
        var candidate = entries
        var candidateBytes = candidate.reduce(Int64(0)) { $0 + $1.byteCount }
        var duplicateCount = 0
        var importedCount = 0
        var usedIDs = Set(candidate.map(\.id))
        try LegacyHistoryImporter.forEachEntry(from: authorizedDirectory, maxEntryBytes: configuration.maxBytes) { entry in
            if candidate.contains(where: { $0.hasIdenticalContent(to: entry) }) {
                duplicateCount += 1
                return
            }
            guard candidate.count < configuration.maxCount,
                  entry.byteCount <= configuration.maxBytes - candidateBytes else {
                throw LegacyHistoryImportError.exceedsLimits
            }
            let value: ClipboardEntry
            if usedIDs.contains(entry.id) {
                value = ClipboardEntry(capturedAt: entry.capturedAt, sourceAppName: entry.sourceAppName,
                                       sourceBundleIdentifier: entry.sourceBundleIdentifier, items: entry.items,
                                       missingTypes: entry.missingTypes, fileBookmarks: entry.fileBookmarks)
            } else { value = entry }
            candidate.append(value)
            candidateBytes += value.byteCount
            usedIDs.insert(value.id)
            importedCount += 1
        }
        if persistenceEnabled {
            if storage == nil { storage = try HistoryPersistence(directory: directory) }
            do { try storage?.save(candidate) }
            catch { throw LegacyHistoryImportError.destinationUnavailable }
        }
        entries = candidate
        return LegacyHistoryImportResult(entries: entries, importedCount: importedCount, duplicateCount: duplicateCount)
    }

    private static func mergeBookmarks(_ old: [ClipboardFileBookmark], _ new: [ClipboardFileBookmark]) -> [ClipboardFileBookmark] {
        var merged = old
        for bookmark in new {
            if let index = merged.firstIndex(where: { FileAccessManager.sameLocation($0.originalURL, bookmark.originalURL) }) {
                merged[index] = bookmark
            } else { merged.append(bookmark) }
        }
        return merged
    }

    private func trim() {
        var bytes = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        while entries.count > configuration.maxCount || bytes > configuration.maxBytes {
            guard let removed = entries.popLast() else { break }
            bytes -= removed.byteCount
        }
    }

    private func save() throws {
        guard persistenceEnabled else { return }
        if storage == nil { storage = try HistoryPersistence(directory: directory) }
        try storage?.save(entries)
    }
}
