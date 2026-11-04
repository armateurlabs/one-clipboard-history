import AppKit
import Foundation
@testable import OneClipboardHistoryCore
import Testing

private final class FakeFileAccess: @unchecked Sendable {
    struct Calls {
        var starts: [URL] = []
        var stops: [URL] = []
        var active = 0
        var checksWithoutScope = 0
        var creationScopes: [Bool] = []
    }
    private let lock = NSLock()
    private var recorded = Calls()
    private let url: URL
    private let status: FileResourceAvailability
    private let started: Bool
    private let stale: Bool
    private let invalid: Bool
    private let movedURL: URL?
    private let creationFails: Bool
    private let scopedCreationFails: Bool
    private let sandboxed: Bool

    init(url: URL, status: FileResourceAvailability = .available, started: Bool = true,
         stale: Bool = false, invalid: Bool = false, movedURL: URL? = nil,
         creationFails: Bool = false, scopedCreationFails: Bool = false, sandboxed: Bool = true) {
        self.url = url; self.status = status; self.started = started; self.stale = stale
        self.invalid = invalid; self.movedURL = movedURL; self.creationFails = creationFails
        self.scopedCreationFails = scopedCreationFails; self.sandboxed = sandboxed
    }

    var calls: Calls { lock.withLock { recorded } }
    var manager: FileAccessManager {
        FileAccessManager(environment: FileAccessEnvironment(
            sandboxed: sandboxed,
            start: { [self] value in
                lock.withLock {
                    recorded.starts.append(value)
                    if started { recorded.active += 1 }
                }
                return started
            },
            stop: { [self] value in
                lock.withLock { recorded.stops.append(value); recorded.active -= 1 }
            },
            availability: { [self] _ in
                lock.withLock { if recorded.active == 0 { recorded.checksWithoutScope += 1 } }
                return status
            },
            createBookmark: { [self] _, scoped in
                lock.withLock { recorded.creationScopes.append(scoped) }
                if creationFails || (scoped && scopedCreationFails) { throw CocoaError(.fileReadNoPermission) }
                return Data("renewed".utf8)
            },
            resolveBookmark: { [self] _, _ in
                if invalid { throw CocoaError(.fileReadCorruptFile) }
                return .init(url: movedURL ?? url, isStale: stale)
            }
        ))
    }
}

@Suite("Sandbox file access metadata and balanced scopes")
struct FileAccessTests {
    private func fileEntry(_ url: URL, bookmark: Data? = nil) -> ClipboardEntry {
        ClipboardEntry(items: [.init(representations: [
            .init(type: "public.file-url", data: Data(url.absoluteString.utf8)),
            .init(type: "app.och.test.metadata", data: Data([0, 255, 2]))
        ])], fileBookmarks: bookmark.map { [.init(originalURL: url, bookmarkData: $0)] } ?? [])
    }

    @Test func capturedGrantIsBalancedAndSeparateFromClipboardIdentity() throws {
        let url = URL(fileURLWithPath: "/tmp/och-sandbox-fixture")
        let backend = FakeFileAccess(url: url)
        let original = fileEntry(url)
        let bookmarks = backend.manager.captureBookmarks(for: [url], authorizedURLs: [url])
        let secured = original.withFileBookmarks(bookmarks)
        #expect(bookmarks.count == 1)
        #expect(bookmarks[0].originalURL == url)
        #expect(secured.items == original.items)
        #expect(secured.byteCount == original.byteCount)
        #expect(secured.contentDigest == original.contentDigest)
        #expect(secured.hasIdenticalContent(to: original))
        #expect(!secured.hasIdenticalStoredValue(to: original))
        #expect(backend.calls.starts == [url])
        #expect(backend.calls.stops == [url])
        #expect(backend.calls.active == 0)
        #expect(backend.calls.checksWithoutScope == 0)
    }

    @Test func deniedAndMissingScopesFailBeforeUseAndCloseExactlyOnce() throws {
        let url = URL(fileURLWithPath: "/tmp/och-denied-fixture")
        for status in [FileResourceAvailability.denied, .missing] {
            let backend = FakeFileAccess(url: url, status: status)
            let session = backend.manager.beginAccess(to: fileEntry(url, bookmark: Data([1])))
            #expect(session.files.isEmpty)
            #expect(session.issues.count == 1)
            #expect(throws: ClipboardFileAccessError.self) { try session.requireAvailableFiles() }
            session.close()
            session.close()
            #expect(backend.calls.stops == [url])
            #expect(backend.calls.active == 0)
        }
    }

    @Test func unavailableInvalidBookmarkDoesNotPretendToGrantAccess() {
        let url = URL(fileURLWithPath: "/tmp/och-invalid-bookmark")
        let backend = FakeFileAccess(url: url, status: .denied, started: false, invalid: true)
        let session = backend.manager.beginAccess(to: fileEntry(url, bookmark: Data([0, 255])))
        defer { session.close() }
        #expect(session.issues.map(\.kind) == [.invalidBookmark])
        #expect(session.files.isEmpty)
        #expect(backend.calls.stops.isEmpty)
    }

    @Test func staleBookmarkIsRenewedWithoutChangingRawPayload() throws {
        let url = URL(fileURLWithPath: "/tmp/och-stale-bookmark")
        let original = fileEntry(url, bookmark: Data("stale".utf8))
        let backend = FakeFileAccess(url: url, stale: true)
        let session = backend.manager.beginAccess(to: original)
        #expect(backend.calls.active == 1)
        try session.requireAvailableFiles()
        let refreshed = try #require(session.refreshedBookmarks)
        #expect(refreshed[0].bookmarkData == Data("renewed".utf8))
        let renewed = original.withFileBookmarks(refreshed)
        #expect(renewed.items == original.items)
        #expect(renewed.contentDigest == original.contentDigest)
        #expect(original.fileBookmarks[0].bookmarkData == Data("stale".utf8))
        session.close()
        #expect(backend.calls.active == 0)
    }

    @Test func staleRenewalFailureIsExplicitButCurrentReadableScopeRemainsUsable() throws {
        let url = URL(fileURLWithPath: "/tmp/och-stale-refresh-failure")
        let backend = FakeFileAccess(url: url, stale: true, creationFails: true)
        let session = backend.manager.beginAccess(to: fileEntry(url, bookmark: Data([1])))
        defer { session.close() }
        #expect(session.issues.map(\.kind) == [.staleBookmark])
        #expect(session.refreshedBookmarks == nil)
        #expect(session.files.count == 1)
        try session.requireAvailableFiles()
    }

    @Test func movedBookmarkNeverSilentlyRewritesAFileURLRepresentation() {
        let old = URL(fileURLWithPath: "/tmp/och-old-file")
        let moved = URL(fileURLWithPath: "/tmp/och-moved-file")
        let original = fileEntry(old, bookmark: Data([1]))
        let backend = FakeFileAccess(url: old, movedURL: moved)
        let session = backend.manager.beginAccess(to: original)
        defer { session.close() }
        #expect(session.issues.map(\.kind) == [.moved])
        #expect(session.files.isEmpty)
        #expect(throws: ClipboardFileAccessError.self) { try session.requireAvailableFiles() }
        #expect(original.items[0].representations[0].data == Data(old.absoluteString.utf8))
    }

    @Test func nonSandboxedReadableURLsStillWorkWithoutSecurityScope() throws {
        let url = URL(fileURLWithPath: "/tmp/och-ordinary-file")
        let backend = FakeFileAccess(url: url, started: false, scopedCreationFails: true, sandboxed: false)
        let bookmarks = backend.manager.captureBookmarks(for: [url], authorizedURLs: [])
        #expect(bookmarks.count == 1)
        #expect(bookmarks[0].isSecurityScoped == false)
        #expect(backend.calls.creationScopes == [false])
        let session = backend.manager.beginAccess(to: fileEntry(url))
        defer { session.close() }
        try session.requireAvailableFiles()
        #expect(session.files.count == 1)
        #expect(backend.calls.stops.isEmpty)
    }

    @Test func failedSandboxBookmarkIsNeverDowngradedToAnUnscopedCredential() {
        let url = URL(fileURLWithPath: "/tmp/och-rejected-sandbox-bookmark")
        let backend = FakeFileAccess(url: url, scopedCreationFails: true, sandboxed: true)
        let bookmarks = backend.manager.captureBookmarks(for: [url], authorizedURLs: [url])
        #expect(bookmarks.isEmpty)
        #expect(backend.calls.creationScopes == [true])
        #expect(backend.calls.active == 0)
        #expect(backend.calls.stops == [url])
    }

    @Test func metadataReadHoldsScopeAndReturnsRenewedCredential() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("och-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fixture.txt")
        try Data(repeating: 42, count: 80).write(to: url)
        let backend = FakeFileAccess(url: url, stale: true)
        let entry = fileEntry(url, bookmark: Data([1]))
        let presentation = ClipboardPresentation.make(for: entry, fileAccessManager: backend.manager)
        #expect(presentation.displayByteCount == 80)
        #expect(presentation.refreshedFileBookmarks?.first?.bookmarkData == Data("renewed".utf8))
        #expect(backend.calls.checksWithoutScope == 0)
        #expect(backend.calls.active == 0)
    }

    @Test @MainActor func deniedScopedFileDoesNotReplacePrivatePasteboard() async throws {
        let name = "app.och.file-access-test.\(UUID())"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("keep", forType: .string)
        let url = URL(fileURLWithPath: "/tmp/och-denied-paste")
        let backend = FakeFileAccess(url: url, status: .denied)
        let service = PasteboardService(pasteboardName: name, fileAccessManager: backend.manager)
        do {
            try await service.write(fileEntry(url, bookmark: Data([1])))
            Issue.record("Denied file access must fail before replacing the clipboard.")
        } catch ClipboardFileAccessError.unavailable { }
        #expect(board.string(forType: .string) == "keep")
        #expect(backend.calls.active == 0)
    }

    @Test @MainActor func namedPasteboardFileCaptureCreatesIndependentBookmarks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("och-file-capture-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("document.txt")
        try Data("fixture".utf8).write(to: url)
        let name = "app.och.file-capture-test.\(UUID())"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        board.clearContents()
        #expect(board.writeObjects([url as NSURL]))
        let service = PasteboardService(pasteboardName: name)
        let entry = try #require(try await service.captureNow())
        #expect(entry.fileBookmarks.count == 1)
        #expect(FileAccessManager.sameLocation(entry.fileBookmarks[0].originalURL, url))
        let raw = entry.items
        try await service.write(entry)
        let restored = try #require(try await PasteboardService(pasteboardName: name).captureNow())
        #expect(restored.items == raw)
        #expect(restored.contentDigest == entry.contentDigest)
    }

    @Test func bookmarkMetadataRoundTripsWithoutChangingLegacyDigest() throws {
        let url = URL(fileURLWithPath: "/tmp/och-persisted-file")
        let original = fileEntry(url)
        let secured = original.withFileBookmarks([.init(originalURL: url, bookmarkData: Data([0, 128, 255]))])
        let bytes = try PropertyListEncoder().encode(secured)
        let restored = try PropertyListDecoder().decode(ClipboardEntry.self, from: bytes)
        #expect(restored.fileBookmarks == secured.fileBookmarks)
        #expect(restored.contentDigest == original.contentDigest)
        var legacy = try #require(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        legacy.removeValue(forKey: "fileBookmarks")
        let legacyBytes = try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
        let old = try PropertyListDecoder().decode(ClipboardEntry.self, from: legacyBytes)
        #expect(old.fileBookmarks.isEmpty)
        #expect(old.items == original.items)
        #expect(old.contentDigest == original.contentDigest)
    }

    @Test func recopyingTheSameFileRefreshesAccessWithoutDuplicatingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("och-bookmark-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HistoryRepository(directory: directory, persistenceEnabled: true)
        let url = URL(fileURLWithPath: "/tmp/och-recopied-file")
        let first = fileEntry(url, bookmark: Data("old".utf8))
        _ = try await repository.insert(first)
        let fresh = fileEntry(url, bookmark: Data("new".utf8))
        let result = try await repository.insert(fresh)
        #expect(result.entries.map(\.id) == [first.id])
        #expect(result.entries[0].fileBookmarks == fresh.fileBookmarks)
        let reopened = try HistoryRepository(directory: directory, persistenceEnabled: true)
        let loaded = try await reopened.load()
        #expect(loaded[0].fileBookmarks == fresh.fileBookmarks)
        #expect(loaded[0].items == first.items)
    }
}
