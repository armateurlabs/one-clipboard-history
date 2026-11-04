import AppKit
import OneClipboardHistoryCore

/// Synthetic, self-contained samples for the actual application UI. They never
/// read the general pasteboard, user files, or another application's contents.
@MainActor
enum DemoFixtures {
    static func entries(in directory: URL) throws -> [ClipboardEntry] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let python = "def greet(name):\n    return f\"Hello, {name}! 👋\"\n"
        let notes = L10n.text("Project notes — formatting preserved")
        let rich = NSAttributedString(string: notes, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.systemBlue
        ])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let png = try makePNG()
        let report = directory.appendingPathComponent("Project notes.txt")
        let image = directory.appendingPathComponent("Mountain sunrise.png")
        let table = directory.appendingPathComponent("Quarterly results.csv")
        try Data("Project notes\n\nAll clipboard examples are synthetic.\n".utf8).write(to: report)
        try png.write(to: image)
        try Data("Quarter,Revenue\nQ1,12500\nQ2,14800\n".utf8).write(to: table)

        func text(_ string: String) -> ClipboardRepresentation {
            .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(string.utf8))
        }
        func entry(_ app: String, _ bundleID: String, _ representations: [ClipboardRepresentation]) -> ClipboardEntry {
            ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 1_793_750_400),
                           sourceAppName: app, sourceBundleIdentifier: bundleID,
                           items: [.init(representations: representations)])
        }
        func file(_ url: URL) -> ClipboardItemSnapshot {
            .init(representations: [.init(type: NSPasteboard.PasteboardType.fileURL.rawValue,
                                         data: Data(url.absoluteString.utf8))])
        }
        // Returned in visible order. seedDemo inserts in reverse so rank 1 is
        // stable and accurately demonstrates the newest-copy-first behavior.
        return [
            entry("TextEdit", "com.apple.TextEdit", [text(L10n.text("Your latest copy, ready to paste."))]),
            entry("Terminal", "com.apple.Terminal", [text(python)]),
            entry("TextEdit", "com.apple.TextEdit", [text(notes),
                .init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf),
                .init(type: NSPasteboard.PasteboardType.html.rawValue,
                      data: Data("<p><strong>\(notes)</strong></p>".utf8))]),
            entry("Preview", "com.apple.Preview", [.init(type: NSPasteboard.PasteboardType.png.rawValue, data: png)]),
            ClipboardEntry(sourceAppName: "Finder", sourceBundleIdentifier: "com.apple.finder", items: [file(report)]),
            ClipboardEntry(sourceAppName: "Finder", sourceBundleIdentifier: "com.apple.finder", items: [file(image), file(table)]),
            entry("Safari", "com.apple.Safari", [text(AppInformation.repositoryURL.absoluteString)]),
            entry("TextEdit", "com.apple.TextEdit", [text(L10n.text("Plain text, rich text, images and files."))])
        ]
    }

    private static func makePNG() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 240,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.coderInvalidValue) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedRed: 0.77, green: 0.88, blue: 0.99, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 320, height: 240).fill()
        NSColor(calibratedRed: 1, green: 0.72, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 220, y: 145, width: 58, height: 58)).fill()
        func mountain(_ points: [NSPoint], color: NSColor) {
            color.setFill()
            let path = NSBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.close()
            path.fill()
        }
        mountain([.init(x: 0, y: 0), .init(x: 0, y: 65), .init(x: 112, y: 190),
                  .init(x: 252, y: 0)], color: NSColor(calibratedRed: 0.41, green: 0.49, blue: 0.72, alpha: 1))
        mountain([.init(x: 90, y: 0), .init(x: 228, y: 152), .init(x: 320, y: 75),
                  .init(x: 320, y: 0)], color: NSColor(calibratedRed: 0.19, green: 0.40, blue: 0.49, alpha: 1))
        mountain([.init(x: 83, y: 157), .init(x: 112, y: 190), .init(x: 148, y: 141),
                  .init(x: 115, y: 151), .init(x: 104, y: 141)], color: .white)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
        return data
    }
}
