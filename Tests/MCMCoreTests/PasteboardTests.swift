import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MCMCore

@Suite("Raw pasteboard fidelity")
struct PasteboardTests {
    @Test @MainActor func stopAndWaitPreventsLaterPollingCallbacks() async throws {
        let name = "app.mcm.tests.\(UUID().uuidString)"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("before stop", forType: .string)
        let service = PasteboardService(pasteboardName: name)
        let captures = CaptureCounter()
        service.start(onCapture: { _ in captures.increment() }, onStatus: { _ in })
        await service.stopAndWait()
        let countAfterBarrier = captures.value
        board.clearContents()
        board.setString("after stop", forType: .string)
        try await Task.sleep(for: .milliseconds(250))
        #expect(captures.value == countAfterBarrier)
    }

    @Test func finderImageReferencesGetOptionalThumbnailWithoutChangingOriginal() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("photo.png")
        let context = try #require(CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8, bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        let image = try #require(context.makeImage())
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let originalImage = png as Data
        try originalImage.write(to: imageURL)
        let originalURLBytes = Data(imageURL.absoluteString.utf8)
        let entry = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: originalURLBytes)])])
        let enriched = ClipboardPresentation.make(for: entry)
        let thumbnail = try #require(enriched.thumbnailData)
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) <= 128)
        #expect((properties[kCGImagePropertyPixelHeight] as? Int ?? 0) <= 128)
        #expect(enriched.fileURLs == [imageURL])
        #expect(enriched.displayByteCount == Int64(originalImage.count))
        #expect(ClipboardPresentation.make(for: entry, includeThumbnail: false).thumbnailData == nil)
        #expect(ClipboardPresentation.placeholder(for: entry).thumbnailData == nil)
        #expect(entry.items[0].representations[0].data == originalURLBytes)
        #expect(try Data(contentsOf: imageURL) == originalImage)
    }

    @Test func directoriesAndUnavailableReferencesHaveUnknownSize() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for url in [folder, folder.appendingPathComponent("unavailable.png")] {
            let entry = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: Data(url.absoluteString.utf8))])])
            #expect(ClipboardPresentation.make(for: entry).displayByteCount == -1)
        }
    }

    @Test func displayDecodingStaysBoundedForLargeTextWithoutChangingOriginal() {
        // A single grapheme can contain millions of combining marks. Character
        // prefixing alone would still decode/copy that entire payload for a row.
        let text = "x" + String(repeating: "\u{0301}", count: 1_000_000) + "\r\n\treturn 42\r\n"
        let original = Data(text.utf8)
        let entry = ClipboardEntry(items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: original)
        ])])
        let placeholder = ClipboardPresentation.placeholder(for: entry)
        let enriched = ClipboardPresentation.make(for: entry)
        #expect(placeholder.title.utf8.count <= 2_048)
        #expect(enriched.title == placeholder.title)
        #expect(!placeholder.title.contains("\u{FFFD}"))
        #expect(entry.items[0].representations[0].data == original)
        #expect(placeholder.displayByteCount == Int64(original.count))
    }

    @Test func boundedTextDecodingRespectsUTF8AndUTF16Boundaries() throws {
        let utf8 = Data(("A" + String(repeating: "\u{0301}", count: 1_022) + "🐍 tail").utf8)
        let utf16 = try #require(("A" + String(repeating: "\u{0301}", count: 1_021) + "🐍 tail").data(using: .utf16))
        for (type, data) in [("public.utf8-plain-text", utf8), ("public.utf16-plain-text", utf16)] {
            let entry = ClipboardEntry(items: [.init(representations: [.init(type: type, data: data)])])
            let presentation = ClipboardPresentation.placeholder(for: entry)
            #expect(presentation.typeName == "Texte brut")
            #expect(presentation.title.unicodeScalars.first?.value == 0x41)
            #expect(!presentation.title.contains("\u{FFFD}"))
            #expect(!presentation.title.contains("🐍"))
            #expect(entry.items[0].representations[0].data == data)
        }
    }

    @Test func placeholdersLeaveFileMetadataAndImageDecodingUnresolved() {
        let file = URL(fileURLWithPath: "/nonexistent-mcm-test/preview.png")
        let fileEntry = ClipboardEntry(items: [.init(representations: [.init(type: "public.file-url", data: Data(file.absoluteString.utf8))])])
        let placeholder = ClipboardPresentation.placeholder(for: fileEntry)
        #expect(placeholder.title == "preview.png")
        #expect(placeholder.fileURLs == [file])
        #expect(placeholder.displayByteCount == -1)
        #expect(placeholder.thumbnailData == nil)
        let imageEntry = ClipboardEntry(items: [.init(representations: [.init(type: "public.png", data: Data([0, 1, 2]))])])
        #expect(ClipboardPresentation.placeholder(for: imageEntry).thumbnailData == nil)
    }

    @Test func materializesDeferredDataFromAnotherProcessOffMainThread() async throws {
        let name = "app.mcm.external-test.\(UUID().uuidString)"
        let source = """
        import AppKit
        final class Provider: NSObject, NSPasteboardItemDataProvider {
            func pasteboard(_ board: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
                precondition(Thread.isMainThread)
                item.setData(Data([1, 2, 3, 4]), forType: type)
            }
        }
        let provider = Provider()
        let board = NSPasteboard(name: .init("\(name)"))
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.init("app.mcm.test.external-data")])
        board.clearContents()
        board.writeObjects([item])
        FileHandle.standardOutput.write(Data("ready\\n".utf8))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 10))
        board.releaseGlobally()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["-e", source]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            NSPasteboard(name: .init(name)).releaseGlobally()
        }
        var ready = Data()
        while ready.last != 0x0A, let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            ready.append(byte)
        }
        #expect(String(data: ready, encoding: .utf8) == "ready\n")
        let captured = try #require(try await PasteboardService(pasteboardName: name).captureNow())
        #expect(captured.isComplete)
        #expect(captured.items[0].representations.first { $0.type == "app.mcm.test.external-data" }?.data == Data([1, 2, 3, 4]))
    }

    @Test @MainActor func providerExceptionBecomesRecoverableFailure() async throws {
        let name = "app.mcm.tests.\(UUID().uuidString)"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        let provider = DeferredProvider(bytes: Data(), raisesException: true)
        let item = NSPasteboardItem()
        #expect(item.setDataProvider(provider, forTypes: [.init("app.mcm.test.throwing-provider")]))
        board.clearContents()
        #expect(board.writeObjects([item]))
        let service = PasteboardService(pasteboardName: name)
        do {
            let captured = try await service.captureNow()
            #expect(captured?.isComplete == false)
        } catch {
            #expect((error as NSError).domain == "app.mcm.pasteboard.communication")
        }
        // The same service must still be usable after the provider misbehaves.
        board.clearContents()
        board.setString("recovered", forType: .string)
        let recovered = try #require(try await service.captureNow())
        #expect(recovered.isComplete)
    }

    @Test @MainActor func materializesDeferredFormatsBeforeOwnershipChanges() async throws {
        let name = "app.mcm.tests.\(UUID().uuidString)"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        let deferredBytes = Data([0xBE, 0xEF, 0x00, 0x42])
        let provider = DeferredProvider(bytes: deferredBytes)
        let item = NSPasteboardItem()
        let promisedType = NSPasteboard.PasteboardType("app.mcm.test.deferred-metadata")
        #expect(item.setDataProvider(provider, forTypes: [promisedType]))
        board.clearContents()
        #expect(board.writeObjects([item]))
        let captured = try #require(try await PasteboardService(pasteboardName: name).captureNow())
        #expect(captured.isComplete)
        #expect(captured.items[0].representations.first { $0.type == promisedType.rawValue }?.data == deferredBytes)
        board.clearContents()
        board.setString("source no longer owns pasteboard", forType: .string)
        try await PasteboardService(pasteboardName: name).write(captured)
        #expect(board.data(forType: promisedType) == deferredBytes)
    }

    @Test @MainActor func snapshotsAndRestoresEveryRepresentationAndItem() async throws {
        let name = "app.mcm.tests.\(UUID().uuidString)"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        let python = Data("def café():\r\n\tprint(\"🐍\")\r\n    return  42\r\n\r\n".utf8)
        let html = Data("<pre><span style=\"color:red\">def café():</span></pre>".utf8)
        let office = Data([0x00, 0x01, 0xFF, 0xC0, 0x42, 0x00])
        let sourceItem = NSPasteboardItem()
        #expect(sourceItem.setData(python, forType: .string))
        #expect(sourceItem.setData(html, forType: .html))
        #expect(sourceItem.setData(office, forType: .init("com.microsoft.word.private-data")))
        let secondItem = NSPasteboardItem()
        let secondBytes = Data("second item\n".utf8)
        #expect(secondItem.setData(secondBytes, forType: .string))
        board.clearContents()
        #expect(board.writeObjects([sourceItem, secondItem]))
        let reader = PasteboardService(pasteboardName: name)
        let entry = try #require(try await reader.captureNow(sourceAppName: "Word", sourceBundleIdentifier: "com.microsoft.Word"))
        #expect(entry.isComplete)
        #expect(entry.items.count == 2)
        #expect(entry.sourceAppName == "Word")
        #expect(entry.items[0].representations.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }?.data == python)
        #expect(entry.items[0].representations.first { $0.type == NSPasteboard.PasteboardType.html.rawValue }?.data == html)
        #expect(entry.items[0].representations.first { $0.type == "com.microsoft.word.private-data" }?.data == office)
        board.clearContents()
        board.setString("different content", forType: .string)
        try await reader.write(entry)
        // A separate service simulates another app, avoiding the writer's self-capture guard.
        let restored = try #require(try await PasteboardService(pasteboardName: name).captureNow())
        #expect(restored.items == entry.items)
        #expect(restored.contentDigest == entry.contentDigest)
        #expect(try await reader.captureNow() == nil)
    }

    @Test @MainActor func incompleteEntryDoesNotOverwriteClipboard() async throws {
        let name = "app.mcm.tests.\(UUID().uuidString)"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("keep me", forType: .string)
        let partial = ClipboardEntry(items: [.init(representations: [
            .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("partial".utf8))
        ])], missingTypes: ["1:com.microsoft.excel.private-data"])
        do {
            try await PasteboardService(pasteboardName: name).write(partial)
            Issue.record("An incomplete entry must not be restored silently")
        } catch PasteboardServiceError.incompleteCapture { }
        #expect(board.string(forType: .string) == "keep me")
    }

    @Test @MainActor func missingFileDoesNotOverwriteClipboard() async throws {
        let name = "app.mcm.tests.\(UUID().uuidString)"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("keep me", forType: .string)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let entry = ClipboardEntry(items: [.init(representations: [
            .init(type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data(missing.absoluteString.utf8))
        ])])
        do {
            try await PasteboardService(pasteboardName: name).write(entry)
            Issue.record("Missing files must prevent restoration")
        } catch PasteboardServiceError.unavailableFiles { }
        #expect(board.string(forType: .string) == "keep me")
    }

    @Test func presentationDoesNotAlterPythonOrPrivateMetadata() throws {
        let bytes = Data("def f():\r\n\treturn  \"é\"\r\n".utf8)
        let metadata = Data([0, 1, 2, 3, 255])
        let entry = ClipboardEntry(items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: bytes),
            .init(type: "com.microsoft.excel.private-data", data: metadata)
        ])])
        let presentation = ClipboardPresentation.make(for: entry)
        #expect(presentation.title.contains("def f():"))
        #expect(presentation.typeName == "Texte brut")
        #expect(entry.items[0].representations[0].data == bytes)
        #expect(entry.items[0].representations[1].data == metadata)
        #expect(presentation.displayByteCount == Int64(bytes.count + metadata.count))
    }

    @Test func fileReferencesAndSizeAreKeptSeparateFromPayloadSize() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.bin")
        let second = folder.appendingPathComponent("second.bin")
        try Data(repeating: 0x42, count: 42).write(to: first)
        try Data(repeating: 0xFF, count: 100).write(to: second)
        let entry = ClipboardEntry(items: [first, second].map { url in
            ClipboardItemSnapshot(representations: [.init(type: "public.file-url", data: Data(url.absoluteString.utf8))])
        })
        let presentation = ClipboardPresentation.make(for: entry)
        #expect(presentation.fileURLs == [first, second])
        #expect(presentation.displayByteCount == 142)
        #expect(ClipboardPresentation.missingFiles(for: entry).isEmpty)
        try FileManager.default.removeItem(at: second)
        #expect(ClipboardPresentation.missingFiles(for: entry) == [second])
    }

    @Test func imagePreviewIsBoundedAndOriginalBytesStayUnchanged() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: 512, height: 256, bitsPerComponent: 8, bytesPerRow: 512 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.7, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "original metadata"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let original = output as Data
        let entry = ClipboardEntry(items: [.init(representations: [.init(type: "public.png", data: original)])])
        let presentation = ClipboardPresentation.make(for: entry)
        let thumbnail = try #require(presentation.thumbnailData)
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) <= 128)
        #expect((properties[kCGImagePropertyPixelHeight] as? Int ?? 0) <= 128)
        #expect(entry.items[0].representations[0].data == original)
        #expect(ClipboardPresentation.make(for: entry, includeThumbnail: false).thumbnailData == nil)
    }
}

private final class DeferredProvider: NSObject, NSPasteboardItemDataProvider {
    let bytes: Data
    let raisesException: Bool

    init(bytes: Data, raisesException: Bool = false) {
        self.bytes = bytes
        self.raisesException = raisesException
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if raisesException {
            NSException(name: .internalInconsistencyException, reason: "Controlled test-provider failure", userInfo: nil).raise()
            return
        }
        item.setData(bytes, forType: type)
    }
}

private final class CaptureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
