# monitor

[![CI](https://github.com/evanwtf/monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/evanwtf/monitor/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/evanwtf/monitor?label=release)](https://github.com/evanwtf/monitor/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/evanwtf/monitor/total?label=downloads)](https://github.com/evanwtf/monitor/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)](https://github.com/evanwtf/monitor/releases/latest)
[![Swift](https://img.shields.io/badge/swift-6.0-orange)](https://swift.org)
[![License](https://img.shields.io/github/license/evanwtf/monitor)](LICENSE)

A standalone macOS system monitor. CPU, GPU, memory, disk and network, in a
window, with charts big enough to actually read.

Not a menu-bar extra. Activity Monitor points in the right direction and gets
two things wrong: the charts are postage stamps, and the history begins the
moment you open the app — so whatever weird blip you went looking for is exactly
the thing it cannot show you.

One Swift package builds three programs: a SwiftUI app, a CSV logging daemon,
and a headless CLI for reading the same metrics from a terminal.

## Screenshot
<img width="1470" height="923" alt="Screenshot 2026-08-12 at 10 55 01 AM" src="https://github.com/user-attachments/assets/cafed6c4-16ec-4af0-9d1b-45d0febf6542" />

## What the repository provides

Three executables, five libraries and a build plugin, in one SwiftPM package.

| Program | What it is | Shipped in the release zip |
|---------|------------|----------------------------|
| `monitor` | The SwiftUI app. Realtime panel of gauges and charts, ten minutes of in-memory history. | yes, as `monitor.app` |
| `monitord` | Headless daemon. Samples every metric on one clock and writes rotating CSV. | yes, as a bare binary |
| `monitorctl` | Headless CLI. Lists, reads and watches the same metrics in a terminal. | no — a development tool |

| Library | What it holds |
|---------|---------------|
| `MonitorCore` | Metric model, ring buffer, downsampling, gauge auto-ranging, formatting, the sampling clock, CSV export, chart axis ticks. No macOS APIs, so it is testable anywhere. |
| `MonitorSources` | The readers — CPU, memory, disk, network, GPU, SMC sensors — and the registry that lists them. |
| `MonitorUI` | The dashboard: theme, gauges, chart cards, preferences, drag-to-reorder, `AppModel`. |
| `MonitorLog` | `CSVLogSink`, the rotating CSV writer. Used by `monitord`; never linked into the app. |
| `MonitorStore` | SQLite history and retention. Written and tested, deliberately **not** linked into any executable — see [docs/storage.md](docs/storage.md). |

`Plugins/StampCommit` is a prebuild plugin that writes the current commit into a
Swift constant, so the app's title bar cannot claim a stale build.

## Download

Grab the latest `monitor-*.zip` from
[Releases](https://github.com/evanwtf/monitor/releases/latest), unzip it, and
drag `monitor.app` to Applications. The zip also contains `monitord`, so a
downloader runs `./monitord` with no toolchain installed.

Releases are ad-hoc signed and not notarized unless the repository's
`SIGN_IDENTITY` and `NOTARY_PROFILE` variables are set, in which case the
release notes say so. When they are not, macOS quarantines the app on first
launch and calls it damaged. Right-click the app and choose Open, then Open
again in the dialog, or clear the flag yourself:

```sh
xattr -d com.apple.quarantine /Applications/monitor.app
```

Building it yourself avoids all of that.

## Usage

### The app

```sh
swift run monitor
```

No Xcode project needed. The app claims a foreground identity at launch, so it
appears in Cmd-Tab and quits with Cmd-Q even as a bare SwiftPM executable.
Cmd-, opens Preferences: **Layout** chooses a gauge and/or chart per metric,
**Charts** controls how cards are drawn, **Sampling** sets the rates. Drag tiles
to rearrange, double-click to zoom, right-click for Copy Image and Copy Data.

To install a real bundle:

```sh
Scripts/make-app.sh ~/Applications
```

### `monitorctl` — read metrics in a terminal

```sh
swift run monitorctl list                                # every source and metric it declares
swift run monitorctl read                                # one reading of everything
swift run monitorctl watch --source disk --interval 0.5
swift run monitorctl watch --json --count 5 | jq         # machine-readable, bounded
```

| Option | Applies to | Meaning |
|--------|-----------|---------|
| `--source <id>` | all | Limit to one source; repeatable. `cpu`, `memory`, `disk`, `network`, `gpu`, `sensors`. |
| `--interval <sec>` | `read`, `watch` | Sampling interval. Default `1.0`. |
| `--json` | `read`, `watch` | One JSON object per sample instead of a table. |
| `--count <n>` | `watch` | Stop after n samples. |

Disk, network and paging are counters, so a rate needs two readings: `read`
takes two ticks itself, and `watch` prints nothing for them on its first line.
That is correct, not a failure.

### `monitord` — log every metric to CSV

```sh
swift run monitord --retention 7d --dir /tmp/logs
./monitord                                               # from the release zip
```

| Option | Meaning |
|--------|---------|
| `--dir <path>` | Directory for the CSV files. Default `~/Library/Logs/monitor`. |
| `--retention <window>` | `1h`, `6h`, `24h`, `48h`, `3d`, `5d`, `7d`, `14d`, `30d`, `forever`. Default `24h`. |
| `--interval <sec>` | Sampling interval. Default `1.0`. |

Files are named `sensors.<host>.<date>_<time>.csv` — one per run, rolling at
local midnight — so several machines can share a directory and a restart never
appends to the previous run's file. Timestamps are ISO8601 in UTC plus epoch
millis, and temperatures appear in both °C and °F. Run it as a launchd
`LaunchAgent` to log for days.

Both CLIs support `--help` and `--version`, print usage for an unrecognised
flag, and exit non-zero rather than starting.

## What it measures

| Group | Metrics | Source |
|-------|---------|--------|
| CPU | total, user, system, and every core separately | `host_processor_info` |
| Memory | app, wired, compressed, cached, free, swap, page in/out | `host_statistics64`, `sysctl` |
| Disk | read/write throughput, IOPS, mean latency | IOKit `IOBlockStorageDriver` |
| Network | in/out throughput and packet rates | `getifaddrs` |
| GPU | utilization, VRAM in use | IOKit `IOAccelerator` |
| Sensors | temperature, fans, power | the SMC |

Per-core CPU is reported separately rather than averaged. On Apple silicon an
efficiency core and a performance core have different ceilings, and the mean of
the two is a number about nothing.

Sensors are found, not assumed. A fanless Mac shows no Fans card rather than one
reading zero, and everything the SMC reads is unprivileged.
[docs/sensors.md](docs/sensors.md) is the survey of what a Mac exposes.

## Build and test

Requires macOS 14 or later and a Swift 6 toolchain. The package resolves one
dependency, Apple's `swift-argument-parser`, so the first build needs a network.

```sh
swift build && swift test                # build and the full suite
swift test --filter GaugeScale           # one suite
swift build -c release                   # CI gates this too
swiftformat Sources Tests Plugins --lint --cache ignore
```

`swiftformat` must be on `PATH` for the lint gate; CI installs it with
`brew install swiftformat` when it is missing. `MonitorSourcesTests` read the
real machine, so they need a real Mac — they assert plausible ranges rather
than values.

CI runs build, test, release build, CLI smoke tests and the format check on
every pull request. Every merge to main ships a release: `release.yml` bumps
the version, tags it, and attaches the zip built by `package.yml`. A
`release:minor`, `release:major` or `release:skip` label on the pull request
changes that; a merge touching only docs and workflows publishes nothing.

## Design notes

A few decisions that are load-bearing rather than incidental:

- **The app writes no history to disk.** A monitor runs all day, every day.
  Writing a sample a second forever costs real SSD endurance for data nobody
  reads, so the app keeps a ten-minute ring buffer in memory and nothing more.
  The dependency graph enforces it — the app does not link `MonitorStore` at
  all. Preferences are the exception, a write per checkbox rather than per
  sample. [docs/storage.md](docs/storage.md) has the arithmetic.
- **`monitord` is the disk logger, and it is a separate binary**, so the app's
  no-disk guarantee holds. It aims at a different consumer: other processes
  correlating performance with temperature or throttling.
- **A gauge is per metric; a chart is per group.** Ticking the chart column for
  Network In and Network Out gives one Network card with both lines, because in
  and out are only readable against each other; ticking the gauge column gives
  two dials, because a dial shows one number.
- **A failed reading is shown as a gap, never as zero.** An idle machine and a
  broken sensor must not look identical. Sources throw; the UI greys the card
  out and says so.
- **Fraction charts are pinned to 0–100%.** Auto-scaling a CPU chart to its own
  2% idle noise is the single most common way a system monitor lies to you.
- **Gauges auto-range and snap to round numbers**, rising immediately and
  falling only after a quiet trailing window, so the needle does not appear to
  move when the value did not.
- **The title bar says which build this is** — the commit and the build time —
  so a monitor left running for days still tells you whether you are looking at
  the change you just made.

## Documentation

[docs/README.md](docs/README.md) is the index. Start there.

Contributors and AI coding agents: [AGENTS.md](AGENTS.md) holds the working
conventions, guardrails and the reasoning behind the boundaries.

## License

MIT. See [LICENSE](LICENSE).
