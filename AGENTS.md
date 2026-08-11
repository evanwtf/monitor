# monitor

## Overview

A standalone macOS system monitor: CPU, GPU, memory, disk and network, in a
window with charts big enough to read. **Not a menu-bar extra.** Activity
Monitor is the closest thing in the right direction, and the two things wrong
with it are the two things this exists to fix — the charts are too small to read
and the history starts when you open the app.

**v1 is realtime and writes nothing to disk.** History lives in a ring buffer in
memory and dies with the process. That is a deliberate scope decision, not an
oversight: the point of v1 is to see what the thing looks like and have it
monitor live. Persistence and a background sampler come later — see
`docs/roadmap.md`.

## Tech Stack

- Swift 6 (`swift-tools-version: 6.0`), SwiftPM, macOS 14+. No third-party
  dependencies.
- SwiftUI, Swift Charts, `Canvas` for the gauges.
- System APIs: mach (`host_processor_info`, `host_statistics64`), IOKit
  (`IOBlockStorageDriver`, `IOAccelerator`), `getifaddrs`, `sysctl`,
  SystemConfiguration (`SCNetworkInterfaceCopyAll`).
- Tests use swift-testing (`@Test`, `#expect`), not XCTest.
- swiftformat (`.swiftformat`) for lint. CI runs on a self-hosted macOS ARM64
  runner.

## Commands

```sh
swift build && swift test        # build + full suite
swift run monitor                # the app — the fast dev loop, no Xcode needed
swift run monitorctl list        # every source and the metrics it declares
swift run monitorctl read        # read every metric once
swift run monitorctl watch --source disk --interval 0.5
swiftformat Sources Tests --lint --cache ignore   # CI lint gate
```

`monitorctl` exists because sampling is the part most likely to be wrong and the
GUI is the worst place to find that out. Work on a source through the CLI, then
look at it in the app.

## Project Layout

```
Sources/
  MonitorCore/     metric model, ring buffer, downsampling, gauge auto-ranging,
                   seven-segment digit mapping, formatting, the sampling clock.
                   No macOS APIs — so all of it is testable without a machine
                   to read.
  MonitorSources/  the readers: CPU, memory, disk, network, GPU, and the registry
                   that lists them. One file per source.
  MonitorUI/       Theme (palette + Layout density), GaugeView, SevenSegmentText,
                   ChartCard, DashboardView, AppModel
  MonitorStore/    SQLite history and retention. Designed and tested but NOT
                   linked into the app — see "Guardrails" below.
  monitor/         the app target (@main SwiftUI App)
  monitorctl/      headless CLI harness
Tests/             MonitorCoreTests, MonitorSourcesTests, MonitorStoreTests
docs/              README.md is the index
```

## Key Concepts

- **`MetricID`** is a stable string key. It is the on-disk key for stored
  history, so renaming one orphans its data.
- **`MetricDescriptor`** is what the UI needs to draw a series — name, group,
  unit, kind — without knowing which source produced it. Cards are laid out by
  `group`.
- **Counter vs gauge**: disk, network and paging report cumulative totals since
  boot. `RateTracker` differentiates them. It returns nil for the first reading
  of a series on purpose, because there is no rate yet and reporting zero would
  draw a dip that did not happen.
- **`GaugeScale`** auto-ranges a dial and snaps full scale to a `ScaleLadder` —
  1-2-5 by default, decades for the throughput dials. It rises immediately and
  falls slowly, stepping down only once the value has stayed clear of the next
  scale down for a continuous `decayInterval`.
- **Throughput units are pinned.** Disk is always MB/s, network always Mbit/s,
  at every magnitude, and the gauge readout is a fixed `xxxx.yy` field whose
  decimal point never moves. The unit under a needle must not change while you
  are reading it. Network converts bytes to bits *in the source*, so the dial,
  the chart axis and `monitorctl` cannot disagree about it.
- **Network counts physical NICs only** — Wi-Fi and wired, via
  `SCNetworkInterfaceCopyAll` filtered to the Ethernet and IEEE80211 types.
  Summing every `getifaddrs` interface double-counts a VPN's traffic (once on
  `utun`, once on the `en` it leaves by) and adds AirDrop and Apple's internal
  interfaces on top.
- **CPU load is per cluster, not per core.** One series per `hw.perflevel`,
  keyed by level because the *name* differs across silicon ("Super" on M4,
  "Performance" earlier). `host_processor_info` numbers cores in reverse
  perflevel order — slowest cluster first.
- **Gauges are for rates, charts are for levels.** A dial answers "how hard is
  this working right now against what it can do" (disk, network throughput). A
  chart answers "what has been happening" (CPU, memory). `AppModel.isGauge`
  encodes the split.

## Code Style & Patterns

- Follow `.swiftformat`: 4-space indent, 96-column soft limit, no `self.` unless
  required, `0..<n` ranges.
- A source is one file, conforms to `MetricSource`, declares its descriptors up
  front, and is added to `SourceRegistry.makeAll()`. That one list feeds the
  app, the CLI and the tests.
- Sources **throw** rather than return zeros. A failed read and an idle system
  must never look the same on a chart; the UI greys the card out instead.
- Formatting lives in `Format`, not in views. The same number appears in a gauge
  readout, a tick label, a chart axis and CLI output, and they have to agree.

## Making Changes

* Make minimal, focused changes; avoid broad refactors unless requested.
* Preserve existing architecture and patterns.
* Don't introduce new dependencies without justification.
* Update tests when behavior changes; update docs when user-visible
  behavior, configuration, or workflows change.

- Verify a UI change by looking at it (`swift run monitor`), not only by
  building. A passing test suite says nothing about whether a needle is legible.
- When adding a metric, decide its `MetricUnit` and `MetricKind` first. Those
  two choices determine the axis, the formatting and whether it needs rate
  differentiation, and getting them wrong produces a chart that is quietly
  wrong rather than obviously broken.

## Guardrails

### Always

- Run `swift build && swift test` and `swiftformat Sources Tests --lint --cache
  ignore` before considering work done. Both are CI gates.
- Keep `MonitorCore` free of macOS system APIs. It is the part that can be
  tested on any machine in any state, and that is worth protecting.

### Never

- **Never make `monitor`, `MonitorUI` or `monitorctl` depend on
  `MonitorStore`.** v1 writes nothing to disk, and the dependency graph is what
  enforces it — the app has no code path that can reach the filesystem. This is
  about SSD endurance: a monitor runs all day, every day, and a careless one
  spends real write cycles on data nobody reads. Adding that dependency is a
  deliberate product decision with an arithmetic argument behind it
  (`docs/storage.md`), never a convenience during a refactor.
- Never report a fabricated value when a source fails. Throw
  `MetricSourceError` and let the UI say "not available". A plausible wrong
  number in a monitoring tool is worse than a gap, because nobody checks it.
- Never auto-scale a `fraction` metric's y-axis. A CPU chart scaled to its own
  2% noise looks like a machine on fire. Fractions are pinned to 0...1.

### Use Extra Caution

- `Sources/MonitorSources/GPUSource.swift` — reads undocumented `IOAccelerator`
  keys that have changed across macOS releases. It looks each one up from a
  candidate list and reports unavailable on a miss. The alternatives (root for
  `powermetrics`, private IOReport) are worse; the file explains why.
- `Sources/MonitorSources/CPUSource.swift` — `host_processor_info` allocates
  into the task's VM and the caller owns it. The `vm_deallocate` in the `defer`
  is not optional; without it the app leaks on every tick, forever.
- `Sources/MonitorSources/DiskSource.swift` — the statistics keys are string
  literals because the `kIOBlockStorageDriver…` constants live in a header that
  is not in IOKit's Swift module map. They are not typos.

## Troubleshooting

- **A rate metric shows nothing on the first tick**: correct by design. Counters
  need two readings. `monitorctl read` takes two ticks for this reason.
- **The window opens behind other apps**: a bare SwiftPM executable has no
  bundle identity, so macOS does not treat it as a foreground app. It is a
  packaging matter, not a bug in the app; a real `.app` bundle fixes it.
- **GPU card is greyed out**: this macOS version does not publish the
  `PerformanceStatistics` keys the source knows about. Add the new spelling to
  the candidate list in `GPUSource`.

## Agent Notes

This file is symlinked to CLAUDE.md and GEMINI.md; keep all instructions
tool-neutral.
