import CSQLite
import CryptoKit
import Darwin
import Foundation

enum HistoryPersistenceError: LocalizedError {
    case sqlite(String)
    case invalidStore(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): L10n.format("History database error: %@", message)
        case .invalidStore(let message): message
        }
    }
}

/// Actor-confined SQLite manifest with independent, lossless binary property-list blobs.
final class HistoryPersistence {
    struct LoadResult {
        let entries: [ClipboardEntry]
        let warnings: [String]
    }

    private struct Record {
        let entry: ClipboardEntry
        let filename: String
        let checksum: String
    }

    private let directory: URL
    private let blobsDirectory: URL
    private var database: OpaquePointer?
    private var records: [UUID: Record] = [:]
    private let manager = FileManager.default

    init(directory: URL) throws {
        self.directory = directory
        blobsDirectory = directory.appendingPathComponent("blobs", isDirectory: true)
        try Self.ensureDirectory(directory)
        try Self.ensureDirectory(blobsDirectory)
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        if manager.fileExists(atPath: databaseURL.path) {
            try Self.requireRegularFile(databaseURL)
        }
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            databaseURL.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? L10n.text("Cannot open database.")
            if let handle { sqlite3_close(handle) }
            throw HistoryPersistenceError.sqlite(message)
        }
        database = handle
        do {
            sqlite3_busy_timeout(handle, 1500)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            let version = try scalarInteger("PRAGMA user_version")
            guard version == 0 || version == 1 else {
                throw HistoryPersistenceError.invalidStore(L10n.text("Unsupported saved history version."))
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS history (
                    id TEXT PRIMARY KEY NOT NULL,
                    position INTEGER NOT NULL UNIQUE,
                    blob TEXT NOT NULL,
                    checksum TEXT NOT NULL
                )
                """)
            try execute("PRAGMA user_version=1")
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func load() throws -> LoadResult {
        let statement = try prepare("SELECT id, blob, checksum FROM history ORDER BY position ASC")
        defer { sqlite3_finalize(statement) }
        var entries: [ClipboardEntry] = []
        var warnings: [String] = []
        var loadedRecords: [UUID: Record] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError() }
            do {
                guard let id = UUID(uuidString: text(statement, 0)) else {
                    throw HistoryPersistenceError.invalidStore(L10n.text("Invalid saved history identifier."))
                }
                let filename = text(statement, 1)
                let checksum = text(statement, 2)
                let url = try blobURL(filename)
                try Self.requireRegularFile(url)
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard Self.checksum(data) == checksum else {
                    throw HistoryPersistenceError.invalidStore(L10n.text("Saved history data failed its integrity check."))
                }
                let entry = try PropertyListDecoder().decode(ClipboardEntry.self, from: data)
                guard entry.id == id else {
                    throw HistoryPersistenceError.invalidStore(L10n.text("Saved history identifier does not match its data."))
                }
                entries.append(entry)
                loadedRecords[id] = Record(entry: entry, filename: filename, checksum: checksum)
            } catch {
                warnings.append(L10n.text("An unavailable or damaged saved clipboard entry was skipped."))
            }
        }
        records = loadedRecords
        return LoadResult(entries: entries, warnings: warnings)
    }

    func save(_ entries: [ClipboardEntry]) throws {
        var nextRecords: [UUID: Record] = [:]
        for entry in entries {
            if let previous = records[entry.id], previous.entry.hasIdenticalStoredValue(to: entry),
               manager.fileExists(atPath: blobsDirectory.appendingPathComponent(previous.filename).path) {
                nextRecords[entry.id] = previous
                continue
            }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(entry)
            let checksum = Self.checksum(data)
            let filename = "\(entry.id.uuidString.lowercased())-\(checksum).entry"
            let url = blobsDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            nextRecords[entry.id] = Record(entry: entry, filename: filename, checksum: checksum)
        }
        // Make new blob directory entries durable before committing references to them.
        try syncDirectory(blobsDirectory)
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM history")
            let statement = try prepare("INSERT INTO history (id, position, blob, checksum) VALUES (?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            for (position, entry) in entries.enumerated() {
                guard let record = nextRecords[entry.id] else { continue }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(entry.id.uuidString, to: statement, at: 1)
                guard sqlite3_bind_int64(statement, 2, Int64(position)) == SQLITE_OK else { throw databaseError() }
                try bind(record.filename, to: statement, at: 3)
                try bind(record.checksum, to: statement, at: 4)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        records = nextRecords
        let live = Set(nextRecords.values.map(\.filename))
        for url in try manager.contentsOfDirectory(at: blobsDirectory, includingPropertiesForKeys: nil) {
            if !live.contains(url.lastPathComponent) { try manager.removeItem(at: url) }
        }
        try syncDirectory(blobsDirectory)
    }

    static func removeSavedHistory(at directory: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw HistoryPersistenceError.invalidStore(L10n.text("The history directory is not a regular directory."))
        }
        for name in ["history.sqlite3", "history.sqlite3-wal", "history.sqlite3-shm", "history.sqlite3-journal", "blobs"] {
            let url = directory.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
    }

    private static func ensureDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw HistoryPersistenceError.invalidStore(L10n.text("A saved history path is not a regular directory."))
            }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func requireRegularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw HistoryPersistenceError.invalidStore(L10n.text("A saved history blob is not a regular file."))
        }
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func blobURL(_ filename: String) throws -> URL {
        guard filename.range(of: "^[a-f0-9-]{36}-[a-f0-9]{64}\\.entry$", options: .regularExpression) != nil else {
            throw HistoryPersistenceError.invalidStore(L10n.text("Invalid saved history blob path."))
        }
        return blobsDirectory.appendingPathComponent(filename)
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard let database, sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        return statement
    }

    private func scalarInteger(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func execute(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw databaseError() }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func databaseError() -> HistoryPersistenceError {
        .sqlite(database.map { String(cString: sqlite3_errmsg($0)) } ?? L10n.text("Database is not open."))
    }
}
