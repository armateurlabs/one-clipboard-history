import AppKit
import Foundation
import OnePasteboardBridge

public enum PasteboardServiceError: LocalizedError, Sendable {
    case accessDenied
    case permissionRequired
    case changedDuringCapture
    case incompleteCapture([String])
    case unavailableFiles([String])
    case unsupportedType(String)
    case sourceContextRequired
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return L10n.text("Clipboard access is denied in System Settings.")
        case .permissionRequired:
            return L10n.text("Open One Clipboard History to allow clipboard access and start capturing.")
        case .changedDuringCapture:
            return L10n.text("The clipboard changed during capture; it will be read again.")
        case .incompleteCapture(let types):
            return L10n.format("Incomplete capture: %ld unavailable representations.", types.count)
        case .unavailableFiles(let paths):
            return L10n.format("Unavailable files: %@.", paths.joined(separator: ", "))
        case .unsupportedType(let type):
            return L10n.format("Cannot restore the %@ format. The clipboard was not changed.", type)
        case .sourceContextRequired:
            return L10n.text("Excel's original clipboard context is no longer available. Confirm raw restoration before continuing.")
        case .writeFailed:
            return L10n.text("macOS could not restore the clipboard contents.")
        }
    }
}

/// Reading permission metadata is safe at login; reading content can prompt.
/// Keep this policy independent of any real pasteboard for deterministic tests.
enum ClipboardPermissionPolicy {
    static func canRead(
        accessBehavior: NSPasteboard.AccessBehavior, allowPermissionPrompts: Bool
    ) -> Bool {
        guard accessBehavior != .alwaysDeny else { return false }
        return allowPermissionPrompts || accessBehavior == .alwaysAllow
    }
}

/// Every pasteboard object and all mutable state are confined to `queue`.
/// Only immutable byte snapshots cross into the app's model and UI.
public final class PasteboardService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.mcm.pasteboard", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let pasteboardName: String?
    private let fileAccess: FileAccessManager
    private var pasteboard: NSPasteboard?
    private var timer: DispatchSourceTimer?
    private var lastObservedCount: Int?
    private var lastOwnWriteCount: Int?
    private var onCapture: (@Sendable (ClipboardEntry) -> Void)?
    private var onStatus: (@Sendable (String?) -> Void)?
    private var previousStatus: String?
    private var polling = false
    private var active = false
    private var permissionPromptsAllowed = true

    public init(pasteboardName: String? = nil, fileAccessManager: FileAccessManager = .init()) {
        self.pasteboardName = pasteboardName
        fileAccess = fileAccessManager
    }

    public func start(
        onCapture: @escaping @Sendable (ClipboardEntry) -> Void,
        onStatus: @escaping @Sendable (String?) -> Void,
        allowPermissionPrompts: Bool = true
    ) {
        queue.async { [self] in
            self.onCapture = onCapture
            self.onStatus = onStatus
            permissionPromptsAllowed = allowPermissionPrompts
            active = true
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(10))
            source.setEventHandler { [weak self] in self?.poll() }
            timer = source
            source.resume()
        }
    }

    /// Called only after an explicit interaction with mcm. Background startup
    /// never grants permission or makes the system display an access request.
    public func allowPermissionRequests() {
        queue.async { [self] in
            permissionPromptsAllowed = true
            poll()
        }
    }

    public func stop() {
        queue.async { [self] in
            active = false
            timer?.cancel()
            timer = nil
            onCapture = nil
            onStatus = nil
        }
    }

    /// Drains work already submitted to the pasteboard queue before returning.
    /// Pending source-app lookups check `active` before performing a later
    /// capture, so callers can then drain their own persistence pipeline.
    public func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                active = false
                timer?.cancel()
                timer = nil
                onCapture = nil
                onStatus = nil
                continuation.resume()
            }
        }
    }

    public func captureNow(
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil
    ) async throws -> ClipboardEntry? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try capture(
                        sourceAppName: sourceAppName,
                        sourceBundleIdentifier: sourceBundleIdentifier
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// A non-mutating preflight for the UI. `write` checks again on its own queue
    /// so a clipboard change after confirmation cannot bypass the default guard.
    public func canPreserveNativeContext(for entry: ClipboardEntry) async throws -> Bool {
        guard entry.isComplete else { return false }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let matches = try withPasteboardBoundary { clipboardMatches(entry, on: board()) }
                    continuation.resume(returning: matches)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func write(_ entry: ClipboardEntry, allowSourceContextLoss: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try withPasteboardBoundary {
                        guard entry.isComplete else {
                            throw PasteboardServiceError.incompleteCapture(entry.missingTypes)
                        }
                        let board = board()
                        // Replacing an identical clipboard needlessly destroys
                        // the original application's ownership and live context
                        // (for example an Office in-process object reference).
                        // A cached digest/changeCount alone is not sufficient:
                        // providers can update already-declared data in place.
                        let preservesOriginal = clipboardMatches(entry, on: board)
                        if entry.requiresExcelSourceContext && !preservesOriginal && !allowSourceContextLoss {
                            throw PasteboardServiceError.sourceContextRequired
                        }
                        let access = fileAccess.beginAccess(to: entry)
                        defer { access.close() }
                        try access.requireAvailableFiles()
                        if preservesOriginal { return }
                        // Prepare every representation before changing the user's pasteboard.
                        let items = try entry.items.map { snapshot in
                            let item = NSPasteboardItem()
                            for representation in snapshot.representations {
                                guard item.setData(representation.data, forType: .init(representation.type)) else {
                                    throw PasteboardServiceError.unsupportedType(representation.type)
                                }
                            }
                            return item
                        }
                        guard !items.isEmpty else { throw PasteboardServiceError.writeFailed }
                        board.clearContents()
                        guard board.writeObjects(items) else { throw PasteboardServiceError.writeFailed }
                        lastOwnWriteCount = board.changeCount
                        lastObservedCount = board.changeCount
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// All reads and the final version check run on the serialized pasteboard
    /// queue. Comparing original order preserves type-preference semantics as
    /// well as bytes. Permission denial must still allow writing an older entry
    /// without attempting a new clipboard read or displaying an access prompt.
    private func clipboardMatches(_ entry: ClipboardEntry, on board: NSPasteboard) -> Bool {
        guard ClipboardPermissionPolicy.canRead(accessBehavior: board.accessBehavior,
                                                 allowPermissionPrompts: false) else { return false }
        let before = board.changeCount
        guard let items = board.pasteboardItems, items.count == entry.items.count else { return false }
        for (item, snapshot) in zip(items, entry.items) {
            let types = item.types
            guard types.map(\.rawValue) == snapshot.representations.map(\.type) else { return false }
            for (type, representation) in zip(types, snapshot.representations) {
                guard let data = item.data(forType: type), data == representation.data else { return false }
            }
        }
        return before == board.changeCount
    }

    private func board() -> NSPasteboard {
        if let pasteboard { return pasteboard }
        let created = pasteboardName.map { NSPasteboard(name: .init($0)) } ?? .general
        pasteboard = created
        return created
    }

    private func poll() {
        guard active, !polling else { return }
        let current: Int
        do {
            current = try withPasteboardBoundary {
                let accessBehavior = board().accessBehavior
                guard ClipboardPermissionPolicy.canRead(
                    accessBehavior: accessBehavior, allowPermissionPrompts: permissionPromptsAllowed
                ) else {
                    throw accessBehavior == .alwaysDeny
                        ? PasteboardServiceError.accessDenied : PasteboardServiceError.permissionRequired
                }
                return board().changeCount
            }
        } catch {
            report(error.localizedDescription)
            return
        }
        guard current != lastObservedCount, current != lastOwnWriteCount else { return }
        polling = true
        // NSWorkspace belongs on the main actor. The slow data providers do not.
        Task { @MainActor [weak self] in
            let frontmost = NSWorkspace.shared.frontmostApplication
            let name = frontmost?.localizedName
            let identifier = frontmost?.bundleIdentifier
            self?.queue.async { [weak self] in
                guard let self else { return }
                defer { self.polling = false }
                guard self.active else { return }
                do {
                    if let entry = try self.capture(sourceAppName: name, sourceBundleIdentifier: identifier,
                                                    allowPermissionPrompts: self.permissionPromptsAllowed) {
                        self.report(entry.isComplete ? nil : PasteboardServiceError.incompleteCapture(entry.missingTypes).localizedDescription)
                        self.onCapture?(entry)
                    }
                } catch {
                    self.report(error.localizedDescription)
                }
            }
        }
    }

    private func capture(sourceAppName: String?, sourceBundleIdentifier: String?,
                         allowPermissionPrompts: Bool = true) throws -> ClipboardEntry? {
        try withPasteboardBoundary {
            try captureUnchecked(sourceAppName: sourceAppName, sourceBundleIdentifier: sourceBundleIdentifier,
                                 allowPermissionPrompts: allowPermissionPrompts)
        }
    }

    private func captureUnchecked(sourceAppName: String?, sourceBundleIdentifier: String?,
                                  allowPermissionPrompts: Bool) throws -> ClipboardEntry? {
        let board = board()
        let accessBehavior = board.accessBehavior
        if accessBehavior == .alwaysDeny { throw PasteboardServiceError.accessDenied }
        guard ClipboardPermissionPolicy.canRead(accessBehavior: accessBehavior,
                                                 allowPermissionPrompts: allowPermissionPrompts) else {
            throw PasteboardServiceError.permissionRequired
        }
        let before = board.changeCount
        guard before != lastObservedCount, before != lastOwnWriteCount else { return nil }
        let originalItems = board.pasteboardItems ?? []
        var snapshots: [ClipboardItemSnapshot] = []
        var missing: [String] = []
        for (index, item) in originalItems.enumerated() {
            var representations: [ClipboardRepresentation] = []
            for type in item.types {
                if let bytes = item.data(forType: type) {
                    representations.append(.init(type: type.rawValue, data: bytes))
                } else {
                    missing.append("\(index + 1):\(type.rawValue)")
                }
            }
            snapshots.append(.init(representations: representations))
        }
        // Some legacy writers offer board-level formats without individual items.
        if originalItems.isEmpty, let types = board.types, !types.isEmpty {
            var representations: [ClipboardRepresentation] = []
            for type in types {
                if let bytes = board.data(forType: type) {
                    representations.append(.init(type: type.rawValue, data: bytes))
                } else {
                    missing.append("1:\(type.rawValue)")
                }
            }
            snapshots.append(.init(representations: representations))
        }
        let fileURLs = ClipboardPresentation.fileURLs(in: snapshots)
        var bookmarks: [ClipboardFileBookmark] = []
        if !fileURLs.isEmpty {
            // NSURL's pasteboard reader receives the sandbox extensions that a
            // URL reconstructed from raw bytes cannot acquire on its own.
            let authorizedURLs = (board.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) ?? []).compactMap { ($0 as? NSURL).map { $0 as URL } }
            defer {
                // Release the implicit scopes delivered by interprocess URL reading.
                for url in authorizedURLs { url.stopAccessingSecurityScopedResource() }
            }
            bookmarks = fileAccess.captureBookmarks(for: fileURLs, authorizedURLs: authorizedURLs)
        }
        guard before == board.changeCount else { throw PasteboardServiceError.changedDuringCapture }
        lastObservedCount = before
        guard !snapshots.isEmpty else { return nil }
        return ClipboardEntry(
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            items: snapshots,
            missingTypes: missing,
            fileBookmarks: bookmarks
        )
    }

    private func report(_ message: String?) {
        guard message != previousStatus else { return }
        previousStatus = message
        onStatus?(message)
    }

    private func withPasteboardBoundary<T>(_ operation: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        do {
            try OCHExceptionBoundary.perform {
                result = Result { try operation() }
            }
        } catch {
            if (error as NSError).domain == "app.mcm.pasteboard.communication" {
                throw NSError(domain: "app.mcm.pasteboard.communication", code: (error as NSError).code,
                              userInfo: [NSLocalizedDescriptionKey: L10n.text("Clipboard communication was interrupted. Capture will be retried.")])
            }
            throw error
        }
        guard let result else { throw PasteboardServiceError.writeFailed }
        return try result.get()
    }
}
