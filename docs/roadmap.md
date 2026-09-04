# Roadmap

What is deliberately not in v1, roughly in the order it is likely to arrive.

## v1 (now)

Realtime only. In-memory ring buffer, nothing written to disk. Gauges for rates,
charts for levels. Runs from `swift run monitor`.

## Persistence and a background sampler

The original motivation: seeing *what just happened* without having kept the app
open. Needs three things:

1. Link `MonitorStore` (already written and tested — see `storage.md`).
2. A background sampler as a launchd `LaunchAgent`, so history accumulates while
   the app is closed. Timeboxed: 24 hours or 7 days, not an archive.
3. A time-range picker in the app that reads from the store rather than the ring
   buffer.

Batched writes are mandatory, not optional. The endurance arithmetic is in
`storage.md`.

**The CSV logger is done.** `monitord` is a headless daemon that samples every
metric on the same clock and writes rotating, human-readable CSV — one file per
day (hourly for a sub-day retention window), hostname in the filename and as a
column, timestamps in ISO8601 and epoch millis. It is the background sampler
half of this step, aimed at a different consumer: other processes that want to
correlate performance with temperature or throttling, rather than the app
reading its own history back. The SQLite store and the app's time-range picker
remain, for the app-side history.

## A real `.app` bundle

Mostly done. `Scripts/make-app.sh` wraps the release binary in `monitor.app`
with an Info.plist and an ad-hoc signature, and the app asks for a foreground
activation policy at launch, so even the bare `swift run monitor` build gets a
Dock icon, a Cmd-Tab entry and Cmd-Q.

What is left is distribution rather than behaviour: an icon, a Developer ID
signature and notarization, which are what another Mac needs before it will open
the app without a warning.

## Per-process attribution

The gap Activity Monitor fills that this does not: when disk write rate spikes,
*which process*. Needs `proc_pid_rusage` or similar, and a different UI shape —
a table, not a gauge.

## More sources

- ~~**Temperature and power.**~~ Done, and the assumption recorded here — that
  both need root or private API — turned out to be wrong. The SMC gives
  temperatures, fan speeds and two verified power rails to an ordinary user;
  `powermetrics` and IOReport are only needed for what the SMC does not carry
  (per-component watts, clock frequency). `docs/sensors.md` has the survey.
- **Per-component power and clock frequency.** What is genuinely left behind
  the private-API line: IOReport's Energy Model has per-core, GPU, ANE and DRAM
  energy, and its P-state residencies are how an average clock is derived.
  Same trade as `GPUSource.swift` discusses — an App Store build could not ship
  it.
- **Per-volume disk breakout.** Today all block devices are summed. The registry
  walk already visits each device separately, so this is mostly a UI question.
- **Per-interface network breakout.** Same shape as above.

## Menu bar

Possible later, explicitly not the point. The app exists because menu-bar
monitors and Activity Monitor both make the charts too small to read.

## Smaller things

- Light theme (a separate palette, not a toggle — see `ui.md`).
- Configurable which cards appear and in what order.
- Alerting on a threshold.
