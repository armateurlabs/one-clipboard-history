import CSQLite
import CryptoKit
import Foundation

public struct LegacyHistoryImportResult: Sendable {
    public let entries: [ClipboardEntry]
    public let importedCount: Int
    public let duplicateCount: Int
}

public enum LegacyHistoryImportError: LocalizedError, Equatable, Sendable {
    case invalidDirectory, invalidArchive, exceedsLimits, destinationUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            L10n.text("Select the legacy History folder containing history.sqlite3 and its blobs folder.")
        case .invalidArchive:
            L10n.text("The selected history is incomplete, damaged or unsupported. Nothing was imported.")
        case .exceedsLimits:
            L10n.text("The combined history exceeds your limits. Increase the history length or data budget before importing.")
        case .destinationUnavailable:
            L10n.text("The imported history could not be saved. Your current history was not replaced.")
        }
    }
}

/// Reads only an explicitly authorized directory. Unlike normal history load,
/// this reader never creates, repairs, trims or deletes any source files.
enum LegacyHistoryImporter {
    /// Holds only the current decoded blob. The consumer must enforce aggregate
    /// limits before retaining an entry and must not publish changes until EOF.
    static func forEachEntry(from directory: URL, maxEntryBytes: Int64,
                             _ consume: (ClipboardEntry) throws -> Void) throws {
        guard directory.isFileURL else { throw LegacyHistoryImportError.invalidDirectory }
        let started = directory.startAccessingSecurityScopedResource()
        defer { if started { directory.stopAccessingSecurityScopedResource() } }
        do {
            guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw LegacyHistoryImportError.invalidDirectory
            }
            let databaseURL = directory.appendingPathComponent("history.sqlite3")
            let blobs = directory.appendingPathComponent("blobs", isDirectory: true)
            try requireRegularFile(databaseURL)
            guard try FileManager.default.attributesOfItem(atPath: blobs.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw LegacyHistoryImportError.invalidDirectory
            }
            try readDatabase(databaseURL, blobsDirectory: blobs, maxEntryBytes: maxEntryBytes, consume: consume)
        } catch let error as LegacyHistoryImportError { throw error }
        catch { throw LegacyHistoryImportError.invalidArchive }
    }

    private static func readDatabase(_ url: URL, blobsDirectory: URL, maxEntryBytes: Int64,
                                     consume: (ClipboardEntry) throws -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw LegacyHistoryImportError.invalidArchive
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1500)
        guard sqlite3_exec(database, "BEGIN DEFERRED TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw LegacyHistoryImportError.invalidArchive
        }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
              let versionStatement else { throw LegacyHistoryImportError.invalidArchive }
        let versionStatus = sqlite3_step(versionStatement)
        let version = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard versionStatus == SQLITE_ROW, version == 0 || version == 1 else { throw LegacyHistoryImportError.invalidArchive }
        // The supported manifest schema guarantees uniqueness in SQLite, so an
        // arbitrarily large archive does not require an in-memory UUID set.
        var schemaStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, """
            SELECT COUNT(*), MAX(CASE WHEN name='id' THEN pk ELSE 0 END)
            FROM pragma_table_info('history') WHERE pk > 0
            """, -1, &schemaStatement, nil) == SQLITE_OK,
              let schemaStatement else { throw LegacyHistoryImportError.invalidArchive }
        let schemaStatus = sqlite3_step(schemaStatement)
        let keyCount = sqlite3_column_int(schemaStatement, 0)
        let idIsKey = sqlite3_column_int(schemaStatement, 1)
        sqlite3_finalize(schemaStatement)
        guard schemaStatus == SQLITE_ROW, keyCount == 1, idIsKey == 1 else {
            throw LegacyHistoryImportError.invalidArchive
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id, blob, checksum FROM history ORDER BY position ASC", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw LegacyHistoryImportError.invalidArchive }
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw LegacyHistoryImportError.invalidArchive }
            // Foundation decoding can autorelease temporary buffers. Drain them
            // per row, including discarded duplicates, rather than at end of import.
            try autoreleasepool {
                let entry = try readEntry(statement, blobsDirectory: blobsDirectory, maxEntryBytes: maxEntryBytes)
                try consume(entry)
            }
        }
    }

    private static func readEntry(_ statement: OpaquePointer, blobsDirectory: URL,
                                   maxEntryBytes: Int64) throws -> ClipboardEntry {
        guard let idText = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: idText)),
              let blobText = sqlite3_column_text(statement, 1),
              let checksumText = sqlite3_column_text(statement, 2) else {
            throw LegacyHistoryImportError.invalidArchive
        }
        let filename = String(cString: blobText)
        let checksum = String(cString: checksumText)
        guard filename.range(of: "^[a-f0-9-]{36}-[a-f0-9]{64}\\.entry$", options: .regularExpression) != nil,
              checksum.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw LegacyHistoryImportError.invalidArchive
        }
        let blob = blobsDirectory.appendingPathComponent(filename)
        try requireRegularFile(blob)
        let size = (try FileManager.default.attributesOfItem(atPath: blob.path)[.size] as? NSNumber)?.int64Value ?? 0
        let (paddedLimit, overflow) = maxEntryBytes.addingReportingOverflow(16 * 1024 * 1024)
        if size > (overflow ? Int64.max : paddedLimit) { throw LegacyHistoryImportError.exceedsLimits }
        let bytes = try Data(contentsOf: blob, options: .mappedIfSafe)
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actual == checksum else { throw LegacyHistoryImportError.invalidArchive }
        let entry = try PropertyListDecoder().decode(ClipboardEntry.self, from: bytes)
        guard entry.id == id else { throw LegacyHistoryImportError.invalidArchive }
        if entry.byteCount > maxEntryBytes { throw LegacyHistoryImportError.exceedsLimits }
        return entry
    }

    private static func requireRegularFile(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw LegacyHistoryImportError.invalidArchive
        }
    }
}
