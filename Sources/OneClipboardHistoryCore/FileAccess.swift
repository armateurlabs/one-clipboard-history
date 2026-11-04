import Foundation
import Security

/// Access credentials belong to this app, not to the copied payload. An absent
/// bookmark in an old history remains decodable and may require user access.
public struct ClipboardFileBookmark: Codable, Hashable, Sendable {
    public let originalURL: URL
    public let bookmarkData: Data
    public let isSecurityScoped: Bool

    public init(originalURL: URL, bookmarkData: Data, isSecurityScoped: Bool = true) {
        self.originalURL = originalURL
        self.bookmarkData = bookmarkData
        self.isSecurityScoped = isSecurityScoped
    }
}

public struct FileAccessIssue: Equatable, Sendable {
    public enum Kind: String, Sendable { case missing, denied, invalidBookmark, moved, staleBookmark }
    public let originalURL: URL
    public let kind: Kind
}

public struct AccessibleClipboardFile: Sendable {
    public let originalURL: URL
    public let resolvedURL: URL
}

public enum ClipboardFileAccessError: LocalizedError, Sendable {
    case unavailable([FileAccessIssue])

    public var errorDescription: String? {
        switch self {
        case .unavailable(let issues):
            if issues.contains(where: { $0.kind == .moved }) {
                return L10n.text("A referenced file moved. Copy it again to preserve the original clipboard formats.")
            }
            return L10n.text("Some referenced files are missing or access was denied. Copy them again from Finder to grant access.")
        }
    }
}

struct ResolvedFileBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

enum FileResourceAvailability: Equatable, Sendable { case available, missing, denied }

/// Injectable OS boundary: tests exercise denial and stale bookmarks without
/// changing the user's sandbox, permissions, filesystem grants or clipboard.
struct FileAccessEnvironment: Sendable {
    let sandboxed: Bool
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void
    let availability: @Sendable (URL) -> FileResourceAvailability
    let createBookmark: @Sendable (URL, Bool) throws -> Data
    let resolveBookmark: @Sendable (Data, Bool) throws -> ResolvedFileBookmark

    static let live = Self(
        sandboxed: {
            guard let task = SecTaskCreateFromSelf(nil),
                  let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) else {
                return false
            }
            return (value as? NSNumber)?.boolValue == true
        }(),
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() },
        availability: { url in
            do {
                guard try url.checkResourceIsReachable() else { return .missing }
                return FileManager.default.isReadableFile(atPath: url.path) ? .available : .denied
            } catch {
                let error = error as NSError
                if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                    || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) {
                    return .denied
                }
                return .missing
            }
        },
        createBookmark: { url, scoped in
            let options: URL.BookmarkCreationOptions = scoped
                ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                : [.withoutImplicitSecurityScope]
            return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolveBookmark: { data, scoped in
            var stale = false
            var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
            if scoped { options.insert(.withSecurityScope) }
            else { options.insert(.withoutImplicitStartAccessing) }
            let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            return ResolvedFileBookmark(url: url, isStale: stale)
        }
    )
}

/// A short-lived, balanced set of scopes. Keep it alive for the actual metadata,
/// image decoding or pasteboard write, then close it even on errors.
public final class FileAccessSession: @unchecked Sendable {
    public let files: [AccessibleClipboardFile]
    public let issues: [FileAccessIssue]
    /// Non-nil only if stale credentials were renewed. Persist separately from payloads.
    public let refreshedBookmarks: [ClipboardFileBookmark]?
    private let lock = NSLock()
    private var leases: [URL]
    private let stop: @Sendable (URL) -> Void

    init(files: [AccessibleClipboardFile], issues: [FileAccessIssue],
         refreshedBookmarks: [ClipboardFileBookmark]?, leases: [URL], stop: @escaping @Sendable (URL) -> Void) {
        self.files = files
        self.issues = issues
        self.refreshedBookmarks = refreshedBookmarks
        self.leases = leases
        self.stop = stop
    }

    public func close() {
        lock.lock()
        let pending = leases
        leases.removeAll()
        lock.unlock()
        for url in pending.reversed() { stop(url) }
    }

    public func requireAvailableFiles() throws {
        let failures = issues.filter { $0.kind != .staleBookmark }
        if !failures.isEmpty { throw ClipboardFileAccessError.unavailable(failures) }
    }

    deinit { close() }
}

public struct FileAccessManager: Sendable {
    private let environment: FileAccessEnvironment

    public init() { environment = .live }
    init(environment: FileAccessEnvironment) { self.environment = environment }

    /// `authorizedURLs` must be NSURLs read by AppKit, not reconstructed from
    /// strings: that read consumes the pasteboard's file-access extensions.
    public func captureBookmarks(for originalURLs: [URL], authorizedURLs: [URL]) -> [ClipboardFileBookmark] {
        originalURLs.compactMap { original in
            let url = authorizedURLs.first { Self.sameLocation($0, original) } ?? original
            let started = environment.start(url)
            defer { if started { environment.stop(url) } }
            guard environment.availability(url) == .available else { return nil }
            // A regular bookmark is sufficient outside App Sandbox and must
            // never masquerade as a durable sandbox grant. Sandboxed builds
            // deliberately do not downgrade a failed scoped bookmark.
            let scoped = environment.sandboxed
            guard let data = try? environment.createBookmark(url, scoped) else { return nil }
            return .init(originalURL: original, bookmarkData: data, isSecurityScoped: scoped)
        }
    }

    public func beginAccess(to entry: ClipboardEntry) -> FileAccessSession {
        beginAccess(to: ClipboardPresentation.fileURLs(for: entry), bookmarks: entry.fileBookmarks)
    }

    func beginAccess(to originalURLs: [URL], bookmarks: [ClipboardFileBookmark]) -> FileAccessSession {
        var files: [AccessibleClipboardFile] = []
        var issues: [FileAccessIssue] = []
        var leases: [URL] = []
        var refreshed = bookmarks
        var didRefresh = false
        for original in originalURLs {
            let bookmarkIndex = bookmarks.firstIndex { Self.sameLocation($0.originalURL, original) }
            var url = original
            var stale = false
            var invalidBookmark = false
            if let bookmarkIndex {
                let bookmark = bookmarks[bookmarkIndex]
                do {
                    let result = try environment.resolveBookmark(bookmark.bookmarkData, bookmark.isSecurityScoped)
                    guard result.url.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
                    url = result.url
                    stale = result.isStale
                } catch {
                    invalidBookmark = true
                    // Existing non-sandboxed histories and resources already
                    // accessible in the container still work by ordinary URL.
                    url = original
                }
            }
            let started = environment.start(url)
            if started { leases.append(url) }
            switch environment.availability(url) {
            case .missing:
                issues.append(.init(originalURL: original, kind: invalidBookmark ? .invalidBookmark : .missing))
                continue
            case .denied:
                issues.append(.init(originalURL: original, kind: invalidBookmark ? .invalidBookmark : .denied))
                continue
            case .available:
                break
            }
            // Bookmarks can follow moves, but rewriting a raw file-URL flavor
            // would violate payload fidelity. Require a fresh copy instead.
            if !Self.sameLocation(url, original) {
                issues.append(.init(originalURL: original, kind: .moved))
                continue
            }
            files.append(.init(originalURL: original, resolvedURL: url))
            if stale, let bookmarkIndex {
                let previous = bookmarks[bookmarkIndex]
                if let data = try? environment.createBookmark(url, previous.isSecurityScoped) {
                    refreshed[bookmarkIndex] = .init(originalURL: original, bookmarkData: data,
                                                     isSecurityScoped: previous.isSecurityScoped)
                    didRefresh = true
                } else {
                    issues.append(.init(originalURL: original, kind: .staleBookmark))
                }
            }
        }
        return FileAccessSession(files: files, issues: issues,
                                 refreshedBookmarks: didRefresh ? refreshed : nil,
                                 leases: leases, stop: environment.stop)
    }

    static func sameLocation(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.absoluteString == second.standardizedFileURL.absoluteString
    }
}
