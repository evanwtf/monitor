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

## A real `.app` bundle

Today `monitor` is a bare SwiftPM executable. It works and it is a fast
development loop, but it has no bundle identity, so macOS does not treat it as a
foreground app and the window opens behind whatever is in front. A proper
bundle brings an icon, an Info.plist, signing, notarization and a Dock identity.

## Per-process attribution

The gap Activity Monitor fills that this does not: when disk write rate spikes,
*which process*. Needs `proc_pid_rusage` or similar, and a different UI shape —
a table, not a gauge.

## More sources

- **Temperature and power.** Wanted, and the honest answer is that both need
  either root (`powermetrics`) or private API (IOReport). Worth revisiting; see
  the discussion in `GPUSource.swift` for the same trade.
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
