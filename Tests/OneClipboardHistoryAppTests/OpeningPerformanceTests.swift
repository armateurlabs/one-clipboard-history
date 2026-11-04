import AppKit
import OneClipboardHistoryCore
import QuartzCore
import Testing
@testable import OneClipboardHistoryApp

/// Opt-in measurement, never a CPU quota or a timing-dependent delivery gate.
/// Measures synchronous AppKit opening/layout/display submission, not the time
/// when the window server presents the first complete frame on the monitor.
@Suite("Warm window measurement", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["OCH_RUN_BENCHMARKS"] == "1"))
@MainActor
struct OpeningPerformanceTests {
    @Test func warmOpeningDistribution() throws {
        _ = NSApplication.shared
        let panel = HistoryPanelController()
        let rows = (1...20).map { number in
            let entry = ClipboardEntry(items: [.init(representations: [
                .init(type: "public.utf8-plain-text", data: Data("Synthetic clipboard entry \(number) — 🐍".utf8))
            ])])
            return HistoryRow(entry: entry, presentation: .placeholder(for: entry))
        }
        panel.update(rows: rows, showPreviews: true, showSizes: true, status: nil)
        let window = try #require(panel.window)
        defer { panel.hide(); window.close() }
        var samples: [Double] = []
        for iteration in 0..<110 {
            let start = ContinuousClock.now
            panel.show(positionAtPointer: false, savedFrame: nil)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            let elapsed = start.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            if iteration >= 10 { samples.append(milliseconds) }
            panel.hide()
        }
        samples.sort()
        #expect(samples.count == 100)
        #expect(samples.allSatisfy { $0.isFinite && $0 >= 0 })
        print(String(format: "opening_appkit_ms samples=100 rows=20 font=12 compact=true p50=%.3f p95=%.3f max=%.3f",
                     samples[49], samples[94], samples[99]))
    }
}
