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

## Screenshot
<img width="1470" height="923" alt="Screenshot 2026-08-12 at 10 55 01 AM" src="https://github.com/user-attachments/assets/cafed6c4-16ec-4af0-9d1b-45d0febf6542" />


## Status

**v1: realtime, in memory, nothing written to disk.**

Rates get analog gauges. Levels get charts. History is a ten-minute ring buffer
that dies with the process — persistence and a background sampler are the next
step, not this one. See `docs/roadmap.md`.

## Download

Grab the latest `monitor-*.zip` from
[Releases](https://github.com/evanwtf/monitor/releases/latest), unzip it, and
drag `monitor.app` to Applications.

The app is signed ad-hoc rather than with a Developer ID, and it is not
notarized, so macOS quarantines it on first launch and says it is damaged.
Right-click the app and choose Open, then Open again in the dialog. Or clear
the flag yourself:

```sh
xattr -d com.apple.quarantine /Applications/monitor.app
```

Building it yourself avoids all of that.

## Running it

```sh
swift run monitor
```

No Xcode project needed. That is the development loop. The app claims a
foreground identity at launch, so it appears in Cmd-Tab and quits with Cmd-Q
like anything else, even though it is a bare SwiftPM executable.

To install it somewhere you can launch it from, build a real bundle:

```sh
Scripts/make-app.sh ~/Applications
```

That produces `monitor.app` — Info.plist, icon, bundle id and an ad-hoc
signature. It is not signed with a Developer ID or notarized, so it is for this
Mac.

There is also a headless CLI, which is how the sampling code gets developed and
verified without a GUI in the way:

```sh
swift run monitorctl list                              # what can be measured
swift run monitorctl read                              # one reading of everything
swift run monitorctl watch --source disk --interval 0.5
swift run monitorctl watch --json | jq                 # machine-readable
swift run monitord --retention 7d --dir /tmp/logs      # rotating CSV logger
```

`monitord` is the logger: it samples every metric on the same clock and writes
rotating, human-readable CSV — one file per run, hostname in the filename and
as a column, timestamps in ISO8601 and epoch millis, temperatures in both °C
and °F. Run it as a launchd `LaunchAgent` to log for days.

With no options it logs at 1s with 1d retention to `~/Library/Logs/monitor`.
The release zip ships a standalone `monitord` binary alongside `monitor.app`, so
a downloader runs `./monitord` — no `swift run` needed.

## What it measures

| Group | Metrics | Source |
|-------|---------|--------|
| CPU | total, user, system, and every core separately | `host_processor_info` |
| Memory | app, wired, compressed, cached, free, swap, page in/out | `host_statistics64`, `sysctl` |
| Disk | read/write throughput, IOPS, mean latency | IOKit `IOBlockStorageDriver` |
| Network | in/out throughput and packet rates | `getifaddrs` |
| GPU | utilization, VRAM in use | IOKit `IOAccelerator` |

Per-core CPU is reported separately rather than averaged. On Apple silicon an
efficiency core and a performance core have different ceilings, and the mean of
the two is a number about nothing.

## Design notes

A few decisions that are load-bearing rather than incidental:

- **No history is written to disk.** A monitor runs all day, every day. Writing
  a sample a second forever costs real SSD endurance for data nobody reads, so
  v1 simply does not. This is enforced by the dependency graph — the app does
  not link the storage library at all — not by anyone remembering. Preferences
  are the one thing that persists, which is a write per checkbox rather than a
  write per sample. `docs/storage.md` works through the arithmetic for when
  history does arrive.
- **A gauge is per metric; a chart is per group.** Cmd-, opens Preferences, and
  its Layout tab lists every metric with a Gauge checkbox and a Chart checkbox.
  Ticking the chart column for Network In and Network Out gives one Network card
  with both lines on it, because in and out are only readable against each
  other; ticking the gauge column gives two dials, because a dial shows one
  number. Sections collapse, and a section heading's checkbox sets the whole
  group at once — it shows a dash when the rows disagree, so a folded section
  still tells you what state it is in. The panel opens with a considered layout — dials for disk and network
  throughput, charts for everything worth glancing at — and this is where you
  disagree with it.
- **A failed reading is shown as a gap, never as zero.** An idle machine and a
  broken sensor must not look identical. Sources throw; the UI greys the card
  out and says so.
- **Fraction charts are pinned to 0–100%.** Auto-scaling a CPU chart to its own
  2% idle noise is the single most common way a system monitor lies to you.
- **Gauges auto-range and snap to round numbers.** A benchmark can pin its dial
  at a known maximum; a monitor cannot, because disk write rate is 2 MB/s during
  a mail sync and 6 GB/s during a restore. Full scale snaps to 1, 2 or 5 times a
  power of ten so the tick labels stay readable, rises immediately, and falls
  only after a quiet trailing window — otherwise the needle appears to move when
  the value did not.

## Documentation

`docs/README.md` is the index. Start there.

## License

MIT. See `LICENSE`.
