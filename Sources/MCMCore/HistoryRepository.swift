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
            entries.insert(existing, at: 0)
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
