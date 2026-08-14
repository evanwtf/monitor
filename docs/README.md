# Documentation

The index. Each file below is the reference for one part of the app.

| Document | What it covers |
|----------|----------------|
| [architecture.md](architecture.md) | The four libraries, what depends on what, and why the boundaries are where they are |
| [metrics.md](metrics.md) | Every metric, its unit and kind, and where the number comes from |
| [sources.md](sources.md) | Writing a new `MetricSource`, and the system APIs each existing one uses |
| [sensors.md](sensors.md) | What a Mac exposes about heat, fans and power, what it costs to read, and what needs root |
| [ui.md](ui.md) | Gauges vs charts, the auto-ranging dial, and the rules that keep a chart honest |
| [storage.md](storage.md) | Why v1 writes nothing to disk, and the SSD-endurance arithmetic for when it does |
| [signing.md](signing.md) | Developer ID signing and notarization: what the app needs, and the one-time setup on the Mac runner |
| [roadmap.md](roadmap.md) | What is deliberately not in v1, in the order it is likely to arrive |

## Quick start

```sh
swift build && swift test
swift run monitor          # the app
swift run monitorctl read  # one reading of every metric
```
