import AppKit
import Dispatch
import Foundation
import Testing
@testable import OneClipboardHistoryCore

@Suite("Clipboard monitoring", .serialized)
@MainActor
struct PasteboardMonitoringTests {
    enum PendingWriter: String, CaseIterable, Sendable {
        case setString, writeObjects
    }

    @Test(arguments: PendingWriter.allCases)
    func anEmptyReadDoesNotConsumeAWriteThatFinishesAtTheSameChangeCount(_ writer: PendingWriter) async throws {
        try await withPrivateMonitor { board, service in
            let captures = MonitoringCaptures()
            #expect(board.setString("before pending writer fixture", forType: .string))
            service.start(onCapture: { captures.append($0) }, onStatus: { _ in })
            try await captures.waitForCount(1)

            let pendingCount = board.clearContents()
            // Deterministically stop between the writer's clear and data
            // publication. Both APIs can fill this ownership without another
            // changeCount increment, so the empty read must leave it eligible
            // for capture when the data arrives.
            #expect(try await service.captureNow() == nil)
            #expect(board.changeCount == pendingCount)
            let text = "def café():\r\n\treturn  '🐍'\r\n\r\n"
            let plain = ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue,
                                                data: Data(text.utf8))
            let expected: [ClipboardRepresentation]
            switch writer {
            case .setString:
                #expect(board.setString(text, forType: .string))
                expected = [plain]
            case .writeObjects:
                let html = ClipboardRepresentation(type: NSPasteboard.PasteboardType.html.rawValue,
                                                   data: Data("<pre><b>def café():</b></pre>".utf8))
                let metadata = ClipboardRepresentation(type: "app.och.fixture.pending-private-format",
                                                       data: Data([0, 255, 7, 0, 42]))
                expected = [plain, html, metadata]
                let item = NSPasteboardItem()
                for representation in expected {
                    #expect(item.setData(representation.data, forType: .init(representation.type)))
                }
                #expect(board.writeObjects([item]))
            }
            #expect(board.changeCount == pendingCount)
            service.allowPermissionRequests()
            try await captures.waitForCount(2)
            await service.stopAndWait()

            #expect(captures.values.count == 2)
            let entry = try #require(captures.values.last?.entry)
            #expect(entry.isComplete)
            #expect(entry.items == [.init(representations: expected)])
        }
    }

    @Test func explicitInteractionCapturesBeforeTheNextTimerTick() async throws {
        try await withPrivateMonitor { board, service in
            let captures = MonitoringCaptures()
            #expect(board.setString("initial monitoring fixture", forType: .string))
            service.start(onCapture: { captures.append($0) }, onStatus: { _ in })
            try await captures.waitForCount(1)

            let python = Data("def café():\r\n\treturn  '🐍'\r\n\r\n".utf8)
            let html = Data("<pre><b>def café():</b></pre>".utf8)
            let item = NSPasteboardItem()
            #expect(item.setData(python, forType: .string))
            #expect(item.setData(html, forType: .html))
            board.clearContents()
            #expect(board.writeObjects([item]))
            service.allowPermissionRequests()
            try await captures.waitForCount(2)
            await service.stopAndWait()

            // This monitor's next timer tick is a minute away; only the
            // explicit interaction can deliver the second independent copy.
            #expect(captures.values.count == 2)
            let entry = try #require(captures.values.last?.entry)
            #expect(entry.isComplete)
            #expect(entry.items == [.init(representations: [
                .init(type: NSPasteboard.PasteboardType.string.rawValue, data: python),
                .init(type: NSPasteboard.PasteboardType.html.rawValue, data: html)
            ])])
        }
    }

    @Test func repeatedStartUsesTheLatestCallbacksWithoutDuplicateDelivery() async throws {
        try await withPrivateMonitor { board, service in
            let original = MonitoringCaptures()
            let replacement = MonitoringCaptures()
            #expect(board.setString("first callback fixture", forType: .string))
            service.start(onCapture: { original.append($0) }, onStatus: { _ in })
            try await original.waitForCount(1)

            service.start(onCapture: { replacement.append($0) }, onStatus: { _ in })
            board.clearContents()
            #expect(board.setString("replacement callback fixture", forType: .string))
            service.allowPermissionRequests()
            service.allowPermissionRequests()
            try await replacement.waitForCount(1)
            await service.stopAndWait()

            #expect(original.values.count == 1)
            #expect(replacement.values.count == 1)
            #expect(replacement.values[0].entry.items[0].representations.contains {
                $0.type == NSPasteboard.PasteboardType.string.rawValue
                    && $0.data == Data("replacement callback fixture".utf8)
            })
        }
    }

    @Test func stoppedMonitorIgnoresExplicitRefreshAndCanRestart() async throws {
        try await withPrivateMonitor { board, service in
            let captures = MonitoringCaptures()
            #expect(board.setString("before stop fixture", forType: .string))
            service.start(onCapture: { captures.append($0) }, onStatus: { _ in })
            try await captures.waitForCount(1)
            await service.stopAndWait()

            board.clearContents()
            #expect(board.setString("after stop fixture", forType: .string))
            service.allowPermissionRequests()
            // Drain the requested refresh while inactive, without reading the
            // copy through captureNow or relying on an arbitrary sleep.
            await service.stopAndWait()
            #expect(captures.values.count == 1)

            service.start(onCapture: { captures.append($0) }, onStatus: { _ in })
            try await captures.waitForCount(2)
            await service.stopAndWait()
            #expect(captures.values.count == 2)
            #expect(captures.values[1].entry.items[0].representations.contains {
                $0.type == NSPasteboard.PasteboardType.string.rawValue
                    && $0.data == Data("after stop fixture".utf8)
            })
        }
    }

    @Test func ownWritesAreNotCapturedByExplicitRefreshOrRestart() async throws {
        try await withPrivateMonitor { board, service in
            let captures = MonitoringCaptures()
            #expect(board.setString("external initial fixture", forType: .string))
            service.start(onCapture: { captures.append($0) }, onStatus: { _ in })
            try await captures.waitForCount(1)

            let ownEntry = ClipboardEntry(items: [.init(representations: [
                .init(type: NSPasteboard.PasteboardType.string.rawValue,
                      data: Data("app-owned restoration fixture".utf8))
            ])])
            try await service.write(ownEntry)
            service.allowPermissionRequests()
            await service.stopAndWait()
            #expect(captures.values.count == 1)

            service.start(onCapture: { captures.append($0) }, onStatus: { _ in })
            service.allowPermissionRequests()
            await service.stopAndWait()
            #expect(captures.values.count == 1)

            board.clearContents()
            #expect(board.setString("next external fixture", forType: .string))
            service.start(onCapture: { captures.append($0) }, onStatus: { _ in })
            try await captures.waitForCount(2)
            await service.stopAndWait()
            #expect(captures.values.count == 2)
            #expect(captures.values[1].entry.items[0].representations.contains {
                $0.type == NSPasteboard.PasteboardType.string.rawValue
                    && $0.data == Data("next external fixture".utf8)
            })
        }
    }
}

/// Opt-in measurement of synthetic writes to a private pasteboard through the
/// monitoring callback. Includes writer IPC, detection, capture and hashing;
/// excludes repository persistence, AppKit rendering and monitor presentation.
/// There is deliberately no performance threshold or CPU admission condition.
@Suite("Clipboard capture latency measurement", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["OCH_BENCHMARK_CAPTURE"] == "1"))
@MainActor
struct PasteboardCapturePerformanceTests {
    @Test func comparePollingIntervals() async throws {
        for interval in [200, 20] {
            let leeway = interval == 200 ? 10 : 2
            try await withPrivateMonitor(pollingInterval: .milliseconds(interval),
                                         timerLeeway: .milliseconds(leeway)) { board, service in
                let captures = MonitoringCaptures()
                #expect(board.setString("synthetic benchmark warm-up", forType: .string))
                service.start(onCapture: { captures.append($0) }, onStatus: { _ in },
                              allowPermissionPrompts: false)
                try await captures.waitForCount(1)
                var milliseconds: [Double] = []
                for index in 0..<30 {
                    // Vary the write phase after the previous callback instead
                    // of measuring only copies aligned with a timer tick.
                    try await Task.sleep(for: .milliseconds((index * 73 + 11) % interval))
                    let bytes = Data("def synthetic_\(index)():\r\n\treturn '🐍 café'\r\n".utf8)
                    let item = NSPasteboardItem()
                    #expect(item.setData(bytes, forType: .string))
                    let began = ContinuousClock.now
                    board.clearContents()
                    #expect(board.writeObjects([item]))
                    try await captures.waitForCount(index + 2)
                    let observation = captures.values[index + 1]
                    #expect(observation.entry.isComplete)
                    #expect(observation.entry.items[0].representations.contains {
                        $0.type == NSPasteboard.PasteboardType.string.rawValue && $0.data == bytes
                    })
                    let elapsed = began.duration(to: observation.receivedAt).components
                    milliseconds.append(Double(elapsed.seconds) * 1_000
                                        + Double(elapsed.attoseconds) / 1e15)
                }
                await service.stopAndWait()
                milliseconds.sort()
                #expect(captures.values.count == 31)
                #expect(milliseconds.count == 30)
                #expect(milliseconds.allSatisfy { $0.isFinite && $0 >= 0 })
                print(String(format: "capture_callback_ms samples=30 polling_ms=%d leeway_ms=%d p50=%.3f p95=%.3f max=%.3f",
                             interval, leeway, milliseconds[14], milliseconds[28], milliseconds[29]))
            }
        }
    }
}

@MainActor
private func withPrivateMonitor(
    pollingInterval: DispatchTimeInterval = .seconds(60),
    timerLeeway: DispatchTimeInterval = .milliseconds(2),
    operation: @MainActor (NSPasteboard, PasteboardService) async throws -> Void
) async throws {
    let name = "app.och.tests.monitoring.\(UUID().uuidString)"
    let board = NSPasteboard(name: .init(name))
    board.clearContents()
    let service = PasteboardService(pasteboardName: name,
                                    pollingInterval: pollingInterval, timerLeeway: timerLeeway)
    do {
        try await operation(board, service)
    } catch {
        await service.stopAndWait()
        board.releaseGlobally()
        throw error
    }
    await service.stopAndWait()
    board.releaseGlobally()
}

private final class MonitoringCaptures: @unchecked Sendable {
    struct Observation: Sendable {
        let entry: ClipboardEntry
        let receivedAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var observations: [Observation] = []
    var values: [Observation] { lock.withLock { observations } }

    func append(_ entry: ClipboardEntry) {
        let receivedAt = ContinuousClock.now
        lock.withLock { observations.append(.init(entry: entry, receivedAt: receivedAt)) }
    }

    func waitForCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while values.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(values.count >= count, "Expected a private-pasteboard monitoring callback")
    }
}
