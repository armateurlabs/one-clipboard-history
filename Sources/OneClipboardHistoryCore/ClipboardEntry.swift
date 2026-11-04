import CryptoKit
import Foundation

/// One exact representation supplied by the copying application.
public struct ClipboardRepresentation: Codable, Hashable, Sendable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// A pasteboard item can expose several alternative representations.
public struct ClipboardItemSnapshot: Codable, Hashable, Sendable {
    public let representations: [ClipboardRepresentation]

    public init(representations: [ClipboardRepresentation]) {
        self.representations = representations
    }
}

/// An independent snapshot; never contains a live NSPasteboardItem or provider.
public struct ClipboardEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let capturedAt: Date
    public let sourceAppName: String?
    public let sourceBundleIdentifier: String?
    public let items: [ClipboardItemSnapshot]
    public let missingTypes: [String]
    /// App-owned access metadata, never a pasteboard representation or part of content identity.
    public let fileBookmarks: [ClipboardFileBookmark]
    private let fingerprint: String

    public init(
        id: UUID = UUID(), capturedAt: Date = Date(),
        sourceAppName: String? = nil, sourceBundleIdentifier: String? = nil,
        items: [ClipboardItemSnapshot], missingTypes: [String] = [],
        fileBookmarks: [ClipboardFileBookmark] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.items = items
        self.missingTypes = missingTypes
        self.fileBookmarks = fileBookmarks
        fingerprint = Self.digest(items: items, missingTypes: missingTypes)
    }

    public var isComplete: Bool {
        missingTypes.isEmpty && !items.isEmpty
            && items.allSatisfy { !$0.representations.isEmpty }
    }

    public var byteCount: Int64 {
        items.reduce(0) { total, item in
            item.representations.reduce(total) { $0 + Int64($1.data.count) }
        }
    }

    public var contentDigest: String { fingerprint }

    /// This observed Excel signature includes a process-bound OLE source. Its
    /// serialized bytes can be complete while historical replay flattens formulas.
    /// Do not infer this dependency from an application name or generic rich text.
    public var requiresExcelSourceContext: Bool {
        items.contains { item in
            let types = Set(item.representations.map(\.type))
            return types.contains("com.microsoft.DataObject")
                && types.contains("com.microsoft.Embed-Source")
                && types.contains(where: { $0.hasPrefix("com.microsoft.ole.source.") })
                && item.representations.contains {
                    $0.type == "com.microsoft.appbundleid"
                        && String(data: $0.data, encoding: .utf8) == "com.microsoft.Excel"
                }
        }
    }

    /// Both item order and representation preference order belong to copied content.
    func hasIdenticalContent(to other: ClipboardEntry) -> Bool {
        fingerprint == other.fingerprint
            && missingTypes.sorted() == other.missingTypes.sorted()
            && items == other.items
    }

    func hasIdenticalStoredValue(to other: ClipboardEntry) -> Bool {
        id == other.id && capturedAt == other.capturedAt
            && sourceAppName == other.sourceAppName
            && sourceBundleIdentifier == other.sourceBundleIdentifier
            && items == other.items && missingTypes == other.missingTypes
            && fileBookmarks == other.fileBookmarks
    }

    public func withFileBookmarks(_ bookmarks: [ClipboardFileBookmark]) -> ClipboardEntry {
        ClipboardEntry(id: id, capturedAt: capturedAt, sourceAppName: sourceAppName,
                       sourceBundleIdentifier: sourceBundleIdentifier, items: items,
                       missingTypes: missingTypes, fileBookmarks: bookmarks)
    }

    private static func digest(items: [ClipboardItemSnapshot], missingTypes: [String]) -> String {
        var hash = SHA256()
        func appendLength(_ value: Int) {
            var number = UInt64(value).bigEndian
            withUnsafeBytes(of: &number) { hash.update(bufferPointer: $0) }
        }
        func append(_ value: Data) {
            appendLength(value.count)
            hash.update(data: value)
        }
        appendLength(items.count)
        for item in items {
            appendLength(item.representations.count)
            for value in item.representations {
                append(Data(value.type.utf8))
                append(value.data)
            }
        }
        appendLength(missingTypes.count)
        for type in missingTypes.sorted() { append(Data(type.utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, sourceAppName, sourceBundleIdentifier, items, missingTypes, fileBookmarks
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            capturedAt: try values.decode(Date.self, forKey: .capturedAt),
            sourceAppName: try values.decodeIfPresent(String.self, forKey: .sourceAppName),
            sourceBundleIdentifier: try values.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier),
            items: try values.decode([ClipboardItemSnapshot].self, forKey: .items),
            missingTypes: try values.decodeIfPresent([String].self, forKey: .missingTypes) ?? [],
            fileBookmarks: try values.decodeIfPresent([ClipboardFileBookmark].self, forKey: .fileBookmarks) ?? []
        )
    }
}

public struct HistoryConfiguration: Sendable {
    public var maxCount: Int
    public var maxBytes: Int64

    public init(maxCount: Int = 20, maxBytes: Int64 = 256 * 1024 * 1024) {
        self.maxCount = max(1, maxCount)
        self.maxBytes = max(1, maxBytes)
    }
}

public struct HistoryUpdate: Sendable {
    public let entries: [ClipboardEntry]
    public let rejectedReason: String?

    public init(entries: [ClipboardEntry], rejectedReason: String? = nil) {
        self.entries = entries
        self.rejectedReason = rejectedReason
    }
}
