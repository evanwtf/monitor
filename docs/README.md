# Documentation

The index. Each file below is the reference for one part of the app.

| Document | What it covers |
|----------|----------------|
| [architecture.md](architecture.md) | The four libraries, what depends on what, and why the boundaries are where they are |
| [metrics.md](metrics.md) | Every metric, its unit and kind, and where the number comes from |
| [sources.md](sources.md) | Writing a new `MetricSource`, and the system APIs each existing one uses |
| [sensors.md](sensors.md) | What a Mac exposes about heat, fans and power, what it costs to read, and what needs root |
| [ui.md](ui.md) | Gauges vs charts, the auto-ranging dial, arranging the panel by dragging, and the rules that keep a chart honest |
| [storage.md](storage.md) | Why v1 writes nothing to disk, and the SSD-endurance arithmetic for when it does |
| [signing.md](signing.md) | What this repository does with a Developer ID: the scripts, the two variables, and the setup on the Mac runner |
| [developer-id-runbook.md](developer-id-runbook.md) | Signing and notarizing a Mac app from nothing, app-agnostic, with the stumbling blocks that cost time |
| [roadmap.md](roadmap.md) | What is deliberately not in v1, in the order it is likely to arrive |

## Quick start

```sh
swift build && swift test
swift run monitor          # the app
swift run monitorctl read  # one reading of every metric
```
