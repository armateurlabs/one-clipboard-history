import AppKit
import Foundation
import Testing
@testable import MCMCore

@Suite("Silent clipboard startup")
struct ClipboardPermissionTests {
    @Test func backgroundPollingReadsOnlyAlreadyAuthorizedContent() {
        #expect(ClipboardPermissionPolicy.canRead(accessBehavior: .alwaysAllow, allowPermissionPrompts: false))
        for behavior: NSPasteboard.AccessBehavior in [.default, .ask, .alwaysDeny] {
            #expect(!ClipboardPermissionPolicy.canRead(accessBehavior: behavior, allowPermissionPrompts: false))
        }
    }

    @Test func interactiveAccessCanRequestPermissionButCannotOverrideDenial() {
        for behavior: NSPasteboard.AccessBehavior in [.default, .ask, .alwaysAllow] {
            #expect(ClipboardPermissionPolicy.canRead(accessBehavior: behavior, allowPermissionPrompts: true))
        }
        #expect(!ClipboardPermissionPolicy.canRead(accessBehavior: .alwaysDeny, allowPermissionPrompts: true))
    }

    @Test @MainActor func silentMonitoringStillCapturesAnAllowedPrivatePasteboard() async throws {
        let name = "app.mcm.permission-tests.\(UUID().uuidString)"
        let board = NSPasteboard(name: .init(name))
        defer { board.releaseGlobally() }
        #expect(board.accessBehavior == .alwaysAllow)
        board.clearContents()
        #expect(board.setString("silent authorized fixture", forType: .string))
        let service = PasteboardService(pasteboardName: name)
        let captures = CapturedEntries()
        service.start(onCapture: { captures.append($0) }, onStatus: { _ in }, allowPermissionPrompts: false)
        for _ in 0..<100 where captures.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await service.stopAndWait()
        let entry = try #require(captures.values.first)
        #expect(entry.isComplete)
        #expect(entry.items[0].representations.contains {
            $0.type == NSPasteboard.PasteboardType.string.rawValue
                && $0.data == Data("silent authorized fixture".utf8)
        })
    }

    private final class CapturedEntries: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [ClipboardEntry] = []
        var values: [ClipboardEntry] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
        func append(_ entry: ClipboardEntry) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(entry)
        }
    }
}
