import AppKit
import Foundation
import MPasteboardBridge

public enum PasteboardServiceError: LocalizedError, Sendable {
    case accessDenied
    case changedDuringCapture
    case incompleteCapture([String])
    case unavailableFiles([String])
    case unsupportedType(String)
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "L’accès au presse-papiers est refusé dans les Réglages Système."
        case .changedDuringCapture:
            return "Le presse-papiers a changé pendant la capture ; une nouvelle lecture sera effectuée."
        case .incompleteCapture(let types):
            return "Capture incomplète : \(types.count) représentation(s) indisponible(s)."
        case .unavailableFiles(let paths):
            return "Fichier(s) indisponible(s) : \(paths.joined(separator: ", "))."
        case .unsupportedType(let type):
            return "Impossible de restaurer le format \(type). Le presse-papiers n’a pas été modifié."
        case .writeFailed:
            return "macOS n’a pas pu restaurer le contenu du presse-papiers."
        }
    }
}

/// Every pasteboard object and all mutable state are confined to `queue`.
/// Only immutable byte snapshots cross into the app's model and UI.
public final class PasteboardService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.mcm.pasteboard", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let pasteboardName: String?
    private var pasteboard: NSPasteboard?
    private var timer: DispatchSourceTimer?
    private var lastObservedCount: Int?
    private var lastOwnWriteCount: Int?
    private var onCapture: (@Sendable (ClipboardEntry) -> Void)?
    private var onStatus: (@Sendable (String?) -> Void)?
    private var previousStatus: String?
    private var polling = false
    private var active = false

    public init(pasteboardName: String? = nil) {
        self.pasteboardName = pasteboardName
    }

    public func start(
        onCapture: @escaping @Sendable (ClipboardEntry) -> Void,
        onStatus: @escaping @Sendable (String?) -> Void
    ) {
        queue.async { [self] in
            self.onCapture = onCapture
            self.onStatus = onStatus
            active = true
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(10))
            source.setEventHandler { [weak self] in self?.poll() }
            timer = source
            source.resume()
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

    public func write(_ entry: ClipboardEntry) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try withPasteboardBoundary {
                        guard entry.isComplete else {
                            throw PasteboardServiceError.incompleteCapture(entry.missingTypes)
                        }
                        let unavailable = ClipboardPresentation.missingFiles(for: entry)
                        guard unavailable.isEmpty else {
                            throw PasteboardServiceError.unavailableFiles(unavailable.map(\.lastPathComponent))
                        }
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
                        let board = board()
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
            current = try withPasteboardBoundary { board().changeCount }
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
                    if let entry = try self.capture(sourceAppName: name, sourceBundleIdentifier: identifier) {
                        self.report(entry.isComplete ? nil : PasteboardServiceError.incompleteCapture(entry.missingTypes).localizedDescription)
                        self.onCapture?(entry)
                    }
                } catch {
                    self.report(error.localizedDescription)
                }
            }
        }
    }

    private func capture(sourceAppName: String?, sourceBundleIdentifier: String?) throws -> ClipboardEntry? {
        try withPasteboardBoundary {
            try captureUnchecked(sourceAppName: sourceAppName, sourceBundleIdentifier: sourceBundleIdentifier)
        }
    }

    private func captureUnchecked(sourceAppName: String?, sourceBundleIdentifier: String?) throws -> ClipboardEntry? {
        let board = board()
        if board.accessBehavior == .alwaysDeny { throw PasteboardServiceError.accessDenied }
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
        guard before == board.changeCount else { throw PasteboardServiceError.changedDuringCapture }
        lastObservedCount = before
        guard !snapshots.isEmpty else { return nil }
        return ClipboardEntry(
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            items: snapshots,
            missingTypes: missing
        )
    }

    private func report(_ message: String?) {
        guard message != previousStatus else { return }
        previousStatus = message
        onStatus?(message)
    }

    private func withPasteboardBoundary<T>(_ operation: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        try MCMExceptionBoundary.perform {
            result = Result { try operation() }
        }
        guard let result else { throw PasteboardServiceError.writeFailed }
        return try result.get()
    }
}
