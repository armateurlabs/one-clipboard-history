import Foundation
@testable import OneClipboardHistoryCore
import Testing

@Suite("Optional durable history")
struct PersistenceTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mcm-persistence-test-\(UUID())")
    }

    private func entry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(
            sourceAppName: "Word", sourceBundleIdentifier: "com.microsoft.Word",
            items: [.init(representations: [
                .init(type: "public.utf8-plain-text", data: Data(text.utf8)),
                .init(type: "com.microsoft.private", data: Data([0, 1, 255, 0, 128]))
            ])]
        )
    }

    @Test func disabledPersistenceNeverCreatesContentFiles() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try HistoryRepository(directory: url)
        _ = try await repository.load()
        _ = try await repository.insert(entry("not on disk"))
        _ = try await repository.configure(.init(maxCount: 10), persistenceEnabled: false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func enableSavesCurrentMemoryAndRestartRestoresExactBytes() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try HistoryRepository(directory: url)
        let first = entry("first\r\n\t🐍"), second = entry("second")
        _ = try await repository.insert(first)
        _ = try await repository.insert(second)
        _ = try await repository.configure(.init(), persistenceEnabled: true)
        let reopened = try HistoryRepository(directory: url, persistenceEnabled: true)
        let loaded = try await reopened.load()
        #expect(loaded.map(\.id) == [second.id, first.id])
        #expect(loaded[1].items == first.items)
        #expect(loaded[1].sourceBundleIdentifier == first.sourceBundleIdentifier)
        #expect(loaded[1].capturedAt == first.capturedAt)
        #expect(await reopened.warnings().isEmpty)
    }

    @Test func disablingRemovesSavedContentButRetainsSession() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try HistoryRepository(directory: url, persistenceEnabled: true)
        let value = entry("retain in memory")
        _ = try await repository.insert(value)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("history.sqlite3").path))
        let memory = try await repository.configure(.init(), persistenceEnabled: false)
        #expect(memory.map(\.id) == [value.id])
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("history.sqlite3").path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("blobs").path))
        _ = try await repository.insert(entry("still not persisted"))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("blobs").path))
    }

    @Test func promotionAndEvictionArePersistedWithoutOrphanBlobs() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try HistoryRepository(directory: url, configuration: .init(maxCount: 2), persistenceEnabled: true)
        let a = entry("a"), b = entry("b"), c = entry("c")
        _ = try await repository.insert(a)
        _ = try await repository.insert(b)
        _ = try await repository.promote(id: a.id)
        _ = try await repository.insert(c)
        let reopened = try HistoryRepository(directory: url, persistenceEnabled: true)
        let loaded = try await reopened.load()
        #expect(loaded.map(\.id) == [c.id, a.id])
        let blobs = try FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
        #expect(blobs.count == 2)
    }

    @Test func missingBlobSkipsOnlyTheUnavailableEntryAndWarns() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try HistoryRepository(directory: url, persistenceEnabled: true)
        let good = entry("good"), missing = entry("missing")
        _ = try await repository.insert(good)
        _ = try await repository.insert(missing)
        let blobs = try FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
        let missingBlob = try #require(blobs.first { $0.lastPathComponent.hasPrefix(missing.id.uuidString.lowercased()) })
        try FileManager.default.removeItem(at: missingBlob)
        let reopened = try HistoryRepository(directory: url, persistenceEnabled: true)
        let loaded = try await reopened.load()
        #expect(loaded.map(\.id) == [good.id])
        #expect(await reopened.warnings().count == 1)
        #expect(await reopened.warnings().isEmpty)
    }

    @Test func damagedBlobIsDetectedAndNewCopiesRemainUsable() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try HistoryRepository(directory: url, persistenceEnabled: true)
        _ = try await repository.insert(entry("original"))
        let blobs = try FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
        let blob = try #require(blobs.first)
        try Data("damaged".utf8).write(to: blob)
        let reopened = try HistoryRepository(directory: url, persistenceEnabled: true)
        #expect(try await reopened.load().isEmpty)
        #expect(await reopened.warnings().count == 1)
        let replacement = entry("replacement")
        let result = try await reopened.insert(replacement)
        #expect(result.entries.map(\.id) == [replacement.id])
    }

    @Test func orphanedAndTemporaryBlobsAreCleanedAfterCommit() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try HistoryRepository(directory: url, persistenceEnabled: true)
        _ = try await repository.insert(entry("live"))
        let orphan = url.appendingPathComponent("blobs/orphan.tmp")
        try Data("orphaned".utf8).write(to: orphan)
        let reopened = try HistoryRepository(directory: url, persistenceEnabled: true)
        _ = try await reopened.load()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func corruptDatabaseWarnsWithoutBreakingMemoryHistory() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: url.appendingPathComponent("history.sqlite3"))
        let repository = try HistoryRepository(directory: url, persistenceEnabled: true)
        #expect(try await repository.load().isEmpty)
        #expect(await repository.warnings().count == 1)
        let value = entry("usable memory")
        do {
            _ = try await repository.insert(value)
            Issue.record("Saving into a corrupt database should report a failure.")
        } catch {
            #expect(await repository.currentEntries().map(\.id) == [value.id])
        }
        _ = try await repository.configure(.init(), persistenceEnabled: false)
        _ = try await repository.configure(.init(), persistenceEnabled: true)
        let reopened = try HistoryRepository(directory: url, persistenceEnabled: true)
        #expect(try await reopened.load().map(\.id) == [value.id])
    }

    @Test func repositoryDoesNotDeleteUnrelatedFilesOnDisable() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try HistoryRepository(directory: url, persistenceEnabled: true)
        _ = try await repository.insert(entry("value"))
        let unrelated = url.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        _ = try await repository.configure(.init(), persistenceEnabled: false)
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
    }
}
