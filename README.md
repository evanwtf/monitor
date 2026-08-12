# monitor

A standalone macOS system monitor. CPU, GPU, memory, disk and network, in a
window, with charts big enough to actually read.

Not a menu-bar extra. Activity Monitor points in the right direction and gets
two things wrong: the charts are postage stamps, and the history begins the
moment you open the app — so whatever weird blip you went looking for is exactly
the thing it cannot show you.

## Status

**v1: realtime, in memory, nothing written to disk.**

Rates get analog gauges. Levels get charts. History is a ten-minute ring buffer
that dies with the process — persistence and a background sampler are the next
step, not this one. See `docs/roadmap.md`.

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

That produces `monitor.app` — Info.plist, bundle id and an ad-hoc signature.
It is not signed with a Developer ID or notarized, so it is for this Mac.

There is also a headless CLI, which is how the sampling code gets developed and
verified without a GUI in the way:

```sh
swift run monitorctl list                              # what can be measured
swift run monitorctl read                              # one reading of everything
swift run monitorctl watch --source disk --interval 0.5
swift run monitorctl watch --json | jq                 # machine-readable
```

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

- **Nothing is written to disk.** A monitor runs all day, every day. Writing a
  sample a second forever costs real SSD endurance for data nobody reads, so v1
  simply does not. This is enforced by the dependency graph — the app does not
  link the storage library at all — not by anyone remembering. `docs/storage.md`
  works through the arithmetic for when persistence does arrive.
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
