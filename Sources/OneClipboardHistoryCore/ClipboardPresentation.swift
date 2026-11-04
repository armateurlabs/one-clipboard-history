import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Display-only interpretation. Never used to rebuild the original pasteboard.
public struct ClipboardPresentation: Sendable {
    public let title: String
    public let detail: String
    public let typeName: String
    public let displayByteCount: Int64
    public let thumbnailData: Data?
    public let fileURLs: [URL]
    public var refreshedFileBookmarks: [ClipboardFileBookmark]? = nil
    public var fileAccessIssues: [FileAccessIssue] = []

    public static func make(for entry: ClipboardEntry, includeThumbnail: Bool = true,
                            fileAccessManager: FileAccessManager = .init()) -> Self {
        build(for: entry, includeThumbnail: includeThumbnail, includeFileMetadata: true, fileAccessManager: fileAccessManager)
    }

    /// Safe for the immediate UI path: bounded text interpretation, no image
    /// decoding and no file-system metadata access. Enrich it on a worker queue.
    public static func placeholder(for entry: ClipboardEntry) -> Self {
        build(for: entry, includeThumbnail: false, includeFileMetadata: false)
    }

    private static func build(for entry: ClipboardEntry, includeThumbnail: Bool, includeFileMetadata: Bool,
                              fileAccessManager: FileAccessManager = .init()) -> Self {
        let representations = entry.items.flatMap(\.representations)
        let files = fileURLs(for: entry)
        let source = entry.sourceAppName.map { L10n.format("Copied from %@", $0) } ?? L10n.text("Unknown source application")
        let captureDetail = entry.isComplete ? source : L10n.format("Incomplete capture · %@", source)
        let warning = entry.requiresExcelSourceContext
            ? L10n.format("Excel formulas need the original clipboard context · %@", captureDetail)
            : captureDetail
        if !files.isEmpty {
            let count = files.count
            let title = count == 1 ? files[0].lastPathComponent : L10n.format("%ld files · %@", count, files.prefix(3).map(\.lastPathComponent).joined(separator: ", "))
            guard includeFileMetadata else {
                return .init(title: title, detail: warning, typeName: count == 1 ? L10n.text("File") : L10n.format("%ld files", count), displayByteCount: -1, thumbnailData: nil, fileURLs: files)
            }
            let session = fileAccessManager.beginAccess(to: entry)
            defer { session.close() }
            let readableFiles = session.files.map(\.resolvedURL)
            let inaccessible = session.issues.contains { $0.kind != .staleBookmark }
            let bytes = inaccessible ? -1 : readableFiles.reduce(Int64(0)) { result, url in
                guard result >= 0 else { return -1 }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true, let size = values?.fileSize else { return -1 }
                return result + Int64(size)
            }
            let type: String
            if readableFiles.count == 1, let uniformType = try? readableFiles[0].resourceValues(forKeys: [.contentTypeKey]).contentType {
                type = uniformType.preferredFilenameExtension.map { L10n.format("%@ file", $0.uppercased()) } ?? L10n.text("File")
            } else {
                type = count == 1 ? L10n.text("File") : L10n.format("%ld files", count)
            }
            let preview: Data?
            if includeThumbnail {
                let firstImage = readableFiles.first { url in
                    (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true
                }
                preview = firstImage.flatMap { thumbnail(from: $0) }
            } else {
                preview = nil
            }
            var result = Self(title: title,
                              detail: inaccessible ? L10n.format("File access unavailable · %@", warning)
                                : session.issues.isEmpty ? warning : L10n.format("File access needs renewal · %@", warning),
                              typeName: type, displayByteCount: bytes, thumbnailData: preview, fileURLs: files)
            result.refreshedFileBookmarks = session.refreshedBookmarks
            result.fileAccessIssues = session.issues
            return result
        }
        let image = representations.first { type($0.type, conformsTo: .image) }
        let html = representations.contains { type($0.type, conformsTo: .html) || $0.type == NSPasteboard.PasteboardType.html.rawValue }
        let rich = representations.contains { type($0.type, conformsTo: .rtf) || $0.type == NSPasteboard.PasteboardType.rtfd.rawValue }
        let plainText = representations.first { representation in
            representation.type == NSPasteboard.PasteboardType.string.rawValue || type(representation.type, conformsTo: .plainText)
        }.flatMap { decodeText($0.data, type: $0.type) }
        let title: String
        let typeName: String
        if let image {
            let uniformType = UTType(image.type)
            title = uniformType?.preferredFilenameExtension.map { L10n.format("%@ image", $0.uppercased()) } ?? L10n.text("Image")
            typeName = title
        } else if let plainText {
            let readable = plainText.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: "    ")
            title = readable.isEmpty ? L10n.text("Empty text") : String(readable.prefix(300))
            typeName = html ? L10n.text("HTML text") : rich ? L10n.text("Rich text") : L10n.text("Plain text")
        } else if html {
            title = L10n.text("HTML content")
            typeName = L10n.text("HTML text")
        } else if rich {
            title = L10n.text("Formatted content")
            typeName = L10n.text("Rich text")
        } else {
            let firstType = representations.first?.type ?? L10n.text("Unavailable format")
            title = UTType(firstType)?.localizedDescription ?? firstType
            typeName = entry.items.count > 1 ? L10n.format("%ld items", entry.items.count) : firstType
        }
        let preview = includeThumbnail ? image.flatMap { thumbnail(from: $0.data) } : nil
        return .init(title: title, detail: warning, typeName: typeName, displayByteCount: entry.byteCount, thumbnailData: preview, fileURLs: [])
    }

    public static func missingFiles(for entry: ClipboardEntry) -> [URL] {
        let session = FileAccessManager().beginAccess(to: entry)
        defer { session.close() }
        return session.issues.filter { $0.kind != .staleBookmark }.map(\.originalURL)
    }

    public static func fileURLs(for entry: ClipboardEntry) -> [URL] {
        fileURLs(in: entry.items)
    }

    public static func fileURLs(in items: [ClipboardItemSnapshot]) -> [URL] {
        var urls: [URL] = []
        for representation in items.flatMap(\.representations) {
            if representation.type == NSPasteboard.PasteboardType.fileURL.rawValue,
               let text = String(data: representation.data, encoding: .utf8),
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.isFileURL {
                if !urls.contains(url) { urls.append(url) }
            } else if representation.type == "NSFilenamesPboardType",
                      let list = try? PropertyListSerialization.propertyList(from: representation.data, format: nil) as? [String] {
                for path in list {
                    let url = URL(fileURLWithPath: path)
                    if !urls.contains(url) { urls.append(url) }
                }
            }
        }
        return urls
    }

    private static func type(_ identifier: String, conformsTo parent: UTType) -> Bool {
        UTType(identifier)?.conforms(to: parent) == true
    }

    private static func decodeText(_ data: Data, type: String) -> String? {
        // A large code/text copy must not be decoded or normalized in full just
        // to paint one row. Preserve the original Data elsewhere unchanged.
        var bytes = Array(data.prefix(2_048))
        let littleEndianBOM = bytes.starts(with: [0xFF, 0xFE])
        let bigEndianBOM = bytes.starts(with: [0xFE, 0xFF])
        if type.contains("utf16") || littleEndianBOM || bigEndianBOM {
            if bytes.count % 2 != 0 { bytes.removeLast() }
            let isLittleEndian = littleEndianBOM || (!bigEndianBOM && !type.contains("big-endian"))
            if bytes.count >= 2 {
                let trailing = bytes.suffix(2)
                let pair = Array(trailing)
                let unit = isLittleEndian ? UInt16(pair[0]) | (UInt16(pair[1]) << 8) : (UInt16(pair[0]) << 8) | UInt16(pair[1])
                if (0xD800...0xDBFF).contains(unit) { bytes.removeLast(2) }
            }
            let encoding: String.Encoding = littleEndianBOM || bigEndianBOM ? .utf16 : isLittleEndian ? .utf16LittleEndian : .utf16BigEndian
            return String(bytes: bytes, encoding: encoding)
        }
        // Truncation can bisect a UTF-8 scalar; trim at most its final 3 bytes.
        for _ in 0..<4 {
            if let text = String(bytes: bytes, encoding: .utf8) {
                return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            }
            guard !bytes.isEmpty else { break }
            bytes.removeLast()
        }
        return nil
    }

    private static func thumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(from: source)
    }

    private static func thumbnail(from url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(from: source)
    }

    private static func thumbnail(from source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
