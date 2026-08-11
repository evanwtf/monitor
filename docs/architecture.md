# Architecture

Four libraries and two executables.

```
monitor (app)        monitorctl (CLI)
      │                    │
   MonitorUI               │
      │                    │
      ├──────► MonitorSources ◄──┤
      │              │
      └──────► MonitorCore ◄─────┘

MonitorStore ──► MonitorCore        (not reachable from the app; see storage.md)
```

## MonitorCore

The metric model and the pure logic: `MetricID`, `MetricDescriptor`, `Sample`,
`TimeSeries`, `Downsample`, `GaugeScale`, `RateTracker`, `Format`, `Sampler`.

**It contains no macOS system APIs.** That is the point of the boundary. Ring
buffer wrap-around, bucket aggregation and dial auto-ranging are exactly the
kind of logic that is easy to get subtly wrong, and keeping them here means they
are tested against fixed inputs rather than against whatever this Mac happened
to be doing.

## MonitorSources

One file per reader, each conforming to `MetricSource`, plus `SourceRegistry`
listing them. The registry is the single place a new source is registered; the
app, the CLI and the tests all build from it.

A source declares its `descriptors` up front, before any data exists, so the UI
can lay out its cards at launch instead of growing them as readings arrive.

`read(at:)` is called on the sampler's own task and must be quick. It **throws**
on failure rather than returning zeros — see `sources.md` for why that matters
more than it sounds.

## MonitorUI

`AppModel` owns the state and drives the sampler; `DashboardView` lays out the
window; `GaugeView` and `ChartCard` draw. `Theme` holds the palette.

`AppModel` calls `Sampler.tick()` itself in a loop rather than registering a
`SampleSink`. Sinks exist for headless consumers; the UI wants the batch back on
the main actor immediately, and a direct call is the shortest path there.

## MonitorStore

SQLite history with tiered retention. Complete and tested, and deliberately not
linked into any executable. `storage.md` explains the reasoning; `Package.swift`
enforces it.

## The sampling clock

One `Sampler` reads every source on one tick, so all metrics in a batch share a
timestamp and line up on the x-axis. Per-core CPU comes from a single
`host_processor_info` call and the cores must not drift apart on the chart.

A source that throws is logged and skipped for that tick. One broken reader
never stops the others — `SourceTests` pins that behaviour, because it is the
kind of thing that regresses silently.
