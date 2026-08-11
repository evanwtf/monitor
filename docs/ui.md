# UI

## Gauges for rates, charts for levels

`AppModel.isGauge` splits them by unit: `bytesPerSecond` and
`operationsPerSecond` get a dial, everything else gets a chart.

The split is not decorative. A dial answers *"how hard is this working right
now, against what it can do"* — the right question for disk and network
throughput. A chart answers *"what has been happening"* — the right question for
CPU and memory, where a needle would just wobble and tell you nothing about the
last two minutes.

## The auto-ranging dial

A benchmark can pin its dial at a known maximum. A monitor cannot: disk write
rate is 2 MB/s while a mail client syncs and 6 GB/s during a restore, and a dial
fixed for either is useless for the other.

`GaugeScale` handles it with two rules:

**Snap full scale to 1, 2 or 5 times a power of ten.** An arbitrary full scale
gives tick labels like 3.7 GB/s, which nobody reads at a glance. Snapping keeps
them round, and ten major divisions always land on readable numbers.

**Rise immediately, fall slowly.** Full scale jumps up the instant a reading
exceeds it, but steps down only after a quiet trailing window (15 s by default).
Otherwise the dial rescales the moment traffic stops and the needle appears to
move when the value did not.

The peak is tracked over a **trailing window, not since launch**. An all-time
peak never decays, so one 900 MB/s spike at breakfast would pin the dial at
1 GB/s for the rest of the day and every subsequent reading would sit uselessly
against the stop. `GaugeScaleTests` pins this.

## Why the needle is a Shape and not part of the Canvas

The face — bezel, ticks, labels, redline — is drawn in a `Canvas`, because none
of it moves.

The needle is a separate `NeedleShape` with `animatableData`. This is not a
style preference. `Canvas` draws imperatively from whatever its closure reads,
so SwiftUI cannot interpolate it: a needle drawn inside the `Canvas` jumps once
per sample and the gauge visibly runs at the sampling rate — at 1 Hz it looks
like 1 fps. A `Shape` with `animatableData` is interpolated at the display
refresh rate and sweeps smoothly between readings.

Needle travel time is set to the sampling interval, so the needle is still
moving when the next sample lands. The cost is that it trails the true value by
up to one interval — the correct trade for an instrument read at a glance.

Animation smooths motion between samples; it cannot invent detail that was never
sampled. That is why the default sampling interval is 0.5 s rather than 1 s.

## Rules that keep a chart honest

**Fractions are pinned to 0–100%.** Auto-scaling a CPU chart to its own 2% idle
noise turns a quiet machine into a dramatic sawtooth. It is the single most
common way a system monitor misleads, and it is one line of code to get wrong.

**A failed reading is a gap, never a zero.** `ChartCard` takes an
`isUnavailable` flag and says "not available on this machine" instead of drawing
a flat line at the bottom, which would be indistinguishable from an idle system.

**Buckets keep min and max, not just the mean.** When history is downsampled to
fit a chart's width, a one-second spike must survive as the bucket's maximum.
Keeping only the mean would hide exactly the events the app exists to show.
`DownsampleTests` pins this.

**Current values live in the card header, beside their colour swatch**, rather
than in a separate legend — the number and the thing that identifies it belong
together, and it saves a row of chrome per card.

## Theme

Dark, and not only as a style choice: this window sits open on a second display
for hours, and a bright panel in the corner of your eye all day is tiring. A
light needle on a dark dial is also the higher-contrast pairing for a thin
moving element.

One needle colour for every gauge. A needle that changes colour per metric turns
a dashboard into a fruit salad and stops the eye reading position, which is the
only thing a needle is for. Chart series colours avoid red/green pairs on the
same chart.
