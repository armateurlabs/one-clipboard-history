# One Clipboard History 1.0.2 validation — 12 November 2026

Version **1.0.2 (12)** reduces capture polling from 200 ms / 10 ms leeway to
20 ms / 2 ms leeway. The reported delay was under half a second. The complete
clipboard snapshot, permission policy, history authority and persistence format
remain unchanged. Earlier checks and qualification limits are retained in
[VALIDATION-1.0.1.md](VALIDATION-1.0.1.md) and its linked reports.

## Capture path and state

`PasteboardService.start` owns a Dispatch timer on its existing serial,
user-initiated queue. `poll` reads access metadata and `changeCount`, then obtains
best-effort source attribution on the main actor. `captureUnchecked` materializes
all exposed representations, checks the change count again and creates the
immutable snapshot and digest before calling `onCapture`. A clipboard change
during capture is retried; own writes and unchanged counts remain suppressed.
No keyboard monitoring, new input permission or CPU admission ceiling was added.

An empty read must not commit the observed count: a writer can clear contents,
then supply formats later under the same ownership/count. Polling skips an empty
type list on the background queue and checks again, avoiding main-actor source
lookups while the writer has no formats. `captureUnchecked` records the observed
count only after a nonempty snapshot exists. This also preserves zero-byte
representations, which still have a declared format.

`AppController.show` already requests a check through `allowPermissionRequests`,
without waiting for the next timer tick. `receive` queues the snapshot for
`HistoryRepository.insert`, the sole owner of ordered history and durable
storage. With persistence enabled, insertion still waits for storage before
updating the panel. Placeholder rows precede asynchronous thumbnail enrichment.
The faster cadence does not discard or defer original formats to accelerate UI.

macOS exposes [`NSPasteboard.changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)
rather than a public global clipboard-change notification. The macOS 27 SDK
header was inspected, and [Chromium's clipboard implementation](https://chromium.googlesource.com/chromium/src/+/refs/tags/137.0.7123.2/remoting/host/clipboard_mac.mm)
documents the same polling constraint. Polling cannot guarantee copies replaced
between reads, and timer cadence is not an end-to-end delivery guarantee.

## Private-pasteboard latency measurement

Host: **Apple M4 Pro, arm64, macOS 27.2.1 (26B131)**. Run:

```sh
OCH_BENCHMARK_CAPTURE=1 swift test --filter PasteboardCapturePerformanceTests
```

The opt-in benchmark writes 30 synthetic Python text copies per configuration to
a uniquely named private pasteboard, varying each write's timer phase. Timing
begins before the writer's pasteboard IPC and ends at the capture callback after
snapshot creation. Every callback's original bytes are checked. It never reads
or replaces the system clipboard and imposes no timing or CPU release threshold.

| Polling / leeway | Samples | p50 | p95 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| 200 ms / 10 ms | 30 | 108.418 ms | 199.983 ms | 204.287 ms |
| 20 ms / 2 ms | 30 | 13.076 ms | 20.290 ms | 21.619 ms |

This measures the timer configuration change within the updated capture path,
not separate installed application binaries. It includes writer IPC, detection,
source lookup and snapshot creation. It excludes history queueing, persistence,
panel updates, pixel delivery, large/deferred providers and the affected Mac.
These observations are not a latency guarantee or an idle CPU/energy comparison.

## Regression checks

`PasteboardMonitoringTests` uses a 60-second timer with a loose 3-second callback
timeout to prove explicit checks bypass the next tick, rather than imposing a
tight performance assertion. Five test functions / six cases cover byte-complete
explicit capture, repeated start/latest callbacks, stop/drain/restart, own-write
suppression and delayed writers. Both the `setString` and `writeObjects` cases
first failed while waiting for the second callback before the empty-write fix;
both passed afterward under the same unchanged counter. The existing suites cover raw bytes
and format order, deferred representations, provider exceptions, permissions,
persistence and shortcut recovery.

Executed checks:

- `swift test`: all active suites passed. Swift Testing reports **85 Core and
  78 AppKit/settings tests**, including one skipped opt-in measurement in each
  target. The capture benchmark above was run separately and passed.
- `python3 -m unittest discover -s scripts/tests -v`: **35 tests passed**.
- `./scripts/build-app.sh` and `./scripts/validate-app.sh`: the direct
  1.0.2 (12) bundle passed resource, localization, signature and metadata checks.
- `python3 scripts/package_release.py --app 'build/One Clipboard History.app'
  --tag v1.0.2 --output-dir build/capture-package-validation`: local ZIP creation,
  extraction and bundle validation passed. This pre-commit diagnostic package
  records a dirty source tree and is not the published artifact.

## Timing diagnostics and limits

Launch the app executable with `--measure` to log durations only:

- `pasteboard_capture_duration`: successful observed change through source lookup and
  complete snapshot creation; excludes the preceding polling wait.
- `history_queue_duration`: time waiting behind earlier queued history work.
- `history_update_duration`: insertion, optional persistence and the initial
  panel update. This does not establish when AppKit/compositor pixels appear.
- `panel_open_duration`: the existing warm opening measurement.

No copied content, source names, paths, types or identifiers are emitted by
these timing fields. Slow source data providers and durable writes can still
take longer than 20 ms. Office fidelity, physical keyboard checks on other Macs,
Developer ID/notarization and Store qualification retain their prior limits.
