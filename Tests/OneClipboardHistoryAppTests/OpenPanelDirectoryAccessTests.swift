import Foundation
import Testing
@testable import OneClipboardHistoryApp

struct OpenPanelDirectoryAccessTests {
    @Test func queuedSelectionReleasesWhenPendingWorkIsDiscarded() {
        let releases = ReleaseCounter()
        var selection: OpenPanelDirectoryAccess? = OpenPanelDirectoryAccess(url: URL(fileURLWithPath: "/synthetic")) { _ in
            releases.increment()
        }
        var pending: (() -> Void)? = { [selection] in withExtendedLifetime(selection) {} }
        selection = nil
        #expect(releases.value == 0)
        #expect(pending != nil)
        pending = nil
        #expect(releases.value == 1)
    }

    @Test func completedWorkReleasesItsSelectionExactlyOnce() {
        let releases = ReleaseCounter()
        var pending: (() -> Void)?
        do {
            let selection = OpenPanelDirectoryAccess(url: URL(fileURLWithPath: "/synthetic")) { _ in
                releases.increment()
            }
            pending = { withExtendedLifetime(selection) {} }
        }
        pending?()
        #expect(releases.value == 0)
        pending = nil
        #expect(releases.value == 1)
    }
}

private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
