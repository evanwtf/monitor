# UI

## Gauges for rates, charts for levels

`AppModel.isGauge` splits them by unit: `bytesPerSecond`, `bitsPerSecond` and
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

**Snap full scale to a ladder.** An arbitrary full scale gives tick labels like
3.7 GB/s, which nobody reads at a glance. Snapping keeps them round, and ten
major divisions always land on readable numbers. Which ladder is per-gauge:

- `ScaleLadder.oneTwoFive` — 10, 20, 50, 100, 200, 500 … The default, and the
  right choice when the range is genuinely unknown, because it keeps the needle
  in a useful part of the sweep.
- `ScaleLadder.decade` — 10, 100, 1000 … Used by the throughput dials. It gives
  up resolution to buy predictability: MB/s and Mbit/s are quoted in tens,
  hundreds and thousands, so a reader already has the ladder in their head and
  needle position alone is enough.

**Rise immediately, fall slowly.** Full scale jumps up the instant a reading
exceeds it, but steps down only once the value has stayed below the next scale
down for a continuous `decayInterval`. Otherwise the dial rescales the moment
traffic stops and the needle appears to move when the value did not.

## The throughput high-water mark

Disk and network dials start at 0–10 MB/s and 0–10 Mbit/s, the scales an idle
machine spends nearly all its time on. Past 10 the scale steps to 100, past 100
to 1000.

Coming down takes **ten minutes below 90% of the next scale down** — below
9 Mbit on the way off the 100 scale. Two details matter:

- The 10% band is hysteresis. Without it, a workload sitting at exactly full
  scale rescales the dial forever, and the needle moves while the value does
  not, which is the one thing a gauge must never do.
- The clock measures *continuous* time below the threshold, not the peak of a
  fixed window. A tumbling window cannot express this rule: the window holding
  the spike also holds the evidence against coming down, so the dial would need
  two full windows — twenty minutes for a ten-minute rule — before it moved.

Once the quiet period is up the dial descends as far as the period's peak
justifies, not one rung at a time: ten quiet minutes takes it from 1000 straight
back to 10 rather than starting a half-hour walk down.

None of it persists. A restart begins at 0–10 again, because v1 writes nothing
to disk.

The `peak` the dial marks is the highest reading since full scale last changed —
the high-water mark that *explains* the current scale, which is what makes a
raised scale readable when nothing is happening. `GaugeScaleTests` and
`DecadeGaugeScaleTests` pin all of this.

## The seven-segment readout

The digital inset in each dial face is drawn as segments, not typeset. macOS
ships no seven-segment font and this project takes no third-party dependencies,
but a font would be the wrong tool regardless: it cannot draw the *unlit*
segments, and those are what make the inset read as a panel with a display in it
rather than a stencil typeface.

`SevenSegment` in MonitorCore holds the character-to-segment mapping, because
"a 4 lights b, c, f and g" is a fact about the display rather than about drawing
and can be tested without a screen. `SevenSegmentText` in MonitorUI draws it.

Two details are load-bearing:

- **Every cell reserves room for its decimal point**, lit or not, exactly as a
  physical part does. Claiming the space only when the point is lit would make
  `2.35` wider than `235`, and a readout that changes width as its value crosses
  a decade is the thing the display exists to prevent. The final cell is the one
  exception — a ghost dot with nothing after it reads as a lit point, turning
  `245` into `245.`.
- **There is no `.contentTransition(.numericText())`.** `Canvas` draws
  imperatively from what its closure reads, so SwiftUI cannot interpolate
  between two readings. The value snaps, which is what an LCD does; the needle
  beside it carries the continuity.

The unit beneath the digits stays ordinary type, because "Mbit/s" is not
expressible in seven segments.

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
