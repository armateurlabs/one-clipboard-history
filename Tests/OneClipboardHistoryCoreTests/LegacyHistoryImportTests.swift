import CSQLite
import CryptoKit
import Foundation
@testable import OneClipboardHistoryCore
import Testing

@Suite("Explicit read-only legacy history import")
struct LegacyHistoryImportTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("och-import-\(UUID())")
    }

    private func entry(_ value: String, id: UUID = UUID()) -> ClipboardEntry {
        ClipboardEntry(id: id, sourceAppName: "Fixture", sourceBundleIdentifier: "app.och.fixture",
                       items: [.init(representations: [
                        .init(type: "public.utf8-plain-text", data: Data(value.utf8)),
                        .init(type: "com.microsoft.fixture.private", data: Data([0, 255, 128, 0]))
                       ])])
    }

    private func archive(_ entries: [ClipboardEntry]) throws -> URL {
        let directory = directory()
        let store = try HistoryPersistence(directory: directory)
        try store.save(entries)
        return directory
    }

    private func sql(_ query: String, in directory: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &database) == SQLITE_OK,
              let database else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, query, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private func contents(_ directory: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    @Test func importMergesWithoutOverwritingAndDoesNotWriteTheSource() async throws {
        let common = entry("common\r\n\t🐍")
        let archived = entry("archived")
        let source = try archive([common, archived])
        let target = directory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let repository = try HistoryRepository(directory: target)
        let current = entry("current")
        let currentCommon = entry("common\r\n\t🐍")
        _ = try await repository.insert(currentCommon)
        _ = try await repository.insert(current)
        let before = try contents(source)
        let result = try await repository.importLegacyHistory(from: source)
        #expect(result.importedCount == 1)
        #expect(result.duplicateCount == 1)
        #expect(result.entries.map(\.id) == [current.id, currentCommon.id, archived.id])
        #expect(result.entries.last?.items == archived.items)
        #expect(try contents(source) == before)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func legacyBlobWithoutBookmarkMetadataStillImportsAndPersists() async throws {
        let original = entry("legacy\r\n\tvalue")
        let source = try archive([original])
        let target = directory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let currentBlob = try #require(try FileManager.default.contentsOfDirectory(
            at: source.appendingPathComponent("blobs"), includingPropertiesForKeys: nil).first)
        var legacy = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: currentBlob), format: nil) as? [String: Any])
        legacy.removeValue(forKey: "fileBookmarks")
        let bytes = try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let filename = "\(original.id.uuidString.lowercased())-\(checksum).entry"
        try bytes.write(to: source.appendingPathComponent("blobs").appendingPathComponent(filename))
        try sql("UPDATE history SET blob='\(filename)', checksum='\(checksum)'", in: source)
        try FileManager.default.removeItem(at: currentBlob)
        let sourceBefore = try contents(source)
        let repository = try HistoryRepository(directory: target, persistenceEnabled: true)
        let result = try await repository.importLegacyHistory(from: source)
        #expect(result.entries[0].items == original.items)
        #expect(result.entries[0].fileBookmarks.isEmpty)
        #expect(result.entries[0].contentDigest == original.contentDigest)
        let reopened = try HistoryRepository(directory: target, persistenceEnabled: true)
        #expect(try await reopened.load()[0].items == original.items)
        #expect(try contents(source) == sourceBefore)
    }

    @Test func collidingIdentifiersKeepBothDifferentPayloads() async throws {
        let id = UUID()
        let current = entry("current", id: id)
        let old = entry("old", id: id)
        let source = try archive([old])
        let target = directory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let repository = try HistoryRepository(directory: target)
        _ = try await repository.insert(current)
        let result = try await repository.importLegacyHistory(from: source)
        #expect(result.entries.count == 2)
        #expect(result.entries[0].id == current.id)
        #expect(result.entries[1].id != old.id)
        #expect(result.entries[1].items == old.items)
        #expect(result.entries[1].contentDigest == old.contentDigest)
    }

    @Test func corruptSourceAbortsTheEntireImportWithoutDroppingCurrentEntries() async throws {
        let source = try archive([entry("valid"), entry("damaged")])
        let target = directory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let damaged = try #require(try FileManager.default.contentsOfDirectory(
            at: source.appendingPathComponent("blobs"), includingPropertiesForKeys: nil).last)
        try Data("corrupt".utf8).write(to: damaged)
        let repository = try HistoryRepository(directory: target, persistenceEnabled: true)
        let current = entry("keep")
        _ = try await repository.insert(current)
        let before = try contents(target)
        do {
            _ = try await repository.importLegacyHistory(from: source)
            Issue.record("A corrupt source must not be partially imported.")
        } catch LegacyHistoryImportError.invalidArchive { }
        #expect(await repository.currentEntries().map(\.id) == [current.id])
        #expect(try contents(target) == before)
    }

    @Test func importOverLimitsDoesNotEvictOrSilentlyTruncate() async throws {
        let source = try archive([entry("first"), entry("second")])
        let target = directory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let repository = try HistoryRepository(directory: target, configuration: .init(maxCount: 2))
        let current = entry("keep")
        _ = try await repository.insert(current)
        do {
            _ = try await repository.importLegacyHistory(from: source)
            Issue.record("An oversized combined history must fail rather than evict entries.")
        } catch LegacyHistoryImportError.exceedsLimits { }
        #expect(await repository.currentEntries().map(\.id) == [current.id])
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func uniqueCountLimitStopsStreamingBeforeLaterBlobsAreRead() async throws {
        let first = entry("first"), second = entry("second"), tail = entry("unread tail")
        let source = try archive([first, second, tail])
        let target = directory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let tailBlob = try #require(try FileManager.default.contentsOfDirectory(
            at: source.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(tail.id.uuidString.lowercased()) })
        try Data("this blob must never be decoded".utf8).write(to: tailBlob)
        let sourceBefore = try contents(source)
        let repository = try HistoryRepository(directory: target, configuration: .init(maxCount: 1))
        do {
            _ = try await repository.importLegacyHistory(from: source)
            Issue.record("The second unique entry must stop the import before reading its corrupt tail.")
        } catch LegacyHistoryImportError.exceedsLimits { }
        #expect(await repository.currentEntries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try contents(source) == sourceBefore)
    }

    @Test func aggregateByteLimitStopsStreamingWithoutPublishingPartialImport() async throws {
        let first = entry("aaaaaaaa"), second = entry("bbbbbbbb"), tail = entry("cccccccc")
        let source = try archive([first, second, tail])
        let target = directory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let tailBlob = try #require(try FileManager.default.contentsOfDirectory(
            at: source.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(tail.id.uuidString.lowercased()) })
        try Data("unread corrupt tail".utf8).write(to: tailBlob)
        // Each entry is individually valid under this budget; two unique
        // entries are not. This exercises the aggregate guard, not blob size.
        let repository = try HistoryRepository(directory: target, configuration: .init(maxCount: 20, maxBytes: 20))
        do {
            _ = try await repository.importLegacyHistory(from: source)
            Issue.record("The aggregate budget must stop the stream before the corrupt tail.")
        } catch LegacyHistoryImportError.exceedsLimits { }
        #expect(await repository.currentEntries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func duplicateArchiveCanBeMuchLargerThanTheRetainedDataBudget() async throws {
        let payload = String(repeating: "x", count: 128 * 1024 - 4)
        let source = try archive((0..<64).map { _ in entry(payload) })
        let target = directory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let repository = try HistoryRepository(directory: target,
            configuration: .init(maxCount: 1, maxBytes: 128 * 1024))
        let result = try await repository.importLegacyHistory(from: source)
        #expect(result.importedCount == 1)
        #expect(result.duplicateCount == 63)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].byteCount == 128 * 1024)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func destinationTransactionFailurePreservesDiskMemoryAndBlobSet() async throws {
        let source = try archive([entry("new imported content")])
        let target = directory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let repository = try HistoryRepository(directory: target, persistenceEnabled: true)
        let current = entry("keep")
        _ = try await repository.insert(current)
        try sql("CREATE TRIGGER fail_import BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT, 'fixture'); END", in: target)
        let before = try contents(target)
        do {
            _ = try await repository.importLegacyHistory(from: source)
            Issue.record("A failed destination commit must abort import.")
        } catch LegacyHistoryImportError.destinationUnavailable { }
        #expect(await repository.currentEntries().map(\.id) == [current.id])
        #expect(try contents(target) == before)
    }

    @Test func malformedManifestPathCannotEscapeTheSelectedDirectory() async throws {
        let source = try archive([entry("value")])
        let target = directory()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        try sql("UPDATE history SET blob='../outside.entry'", in: source)
        let repository = try HistoryRepository(directory: target)
        do {
            _ = try await repository.importLegacyHistory(from: source)
            Issue.record("A traversal path must be rejected.")
        } catch LegacyHistoryImportError.invalidArchive { }
        #expect(await repository.currentEntries().isEmpty)
    }

    @Test func selectingCurrentHistoryCannotRewriteItAsAnImport() async throws {
        let target = directory()
        defer { try? FileManager.default.removeItem(at: target) }
        let repository = try HistoryRepository(directory: target, persistenceEnabled: true)
        _ = try await repository.insert(entry("keep"))
        let before = try contents(target)
        do {
            _ = try await repository.importLegacyHistory(from: target)
            Issue.record("Current history is not an external legacy source.")
        } catch LegacyHistoryImportError.invalidDirectory { }
        #expect(try contents(target) == before)
    }

    @Test func missingOrNonFileSourceFailsWithoutCreatingDestination() async throws {
        let target = directory()
        defer { try? FileManager.default.removeItem(at: target) }
        let repository = try HistoryRepository(directory: target)
        do {
            _ = try await repository.importLegacyHistory(from: URL(string: "https://example.invalid/History")!)
            Issue.record("Only an authorized local directory can be imported.")
        } catch LegacyHistoryImportError.invalidDirectory { }
        do {
            _ = try await repository.importLegacyHistory(from: directory())
            Issue.record("Missing source must fail.")
        } catch LegacyHistoryImportError.invalidArchive { }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
