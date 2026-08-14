# UI

## Gauges for rates, charts for levels

`LayoutDefaults` splits them: disk and network throughput open with a dial,
everything the panel draws opens with a chart.

The split is not decorative. A dial answers *"how hard is this working right
now, against what it can do"* — the right question for disk and network
throughput. A chart answers *"what has been happening"* — the right question for
CPU and memory, where a needle would just wobble and tell you nothing about the
last two minutes.

It is a default rather than a rule. Every metric can have either, both or
neither, chosen per metric in preferences — see below.

## Choosing the layout

Preferences (Cmd-,) is a tabbed window with one tab, Layout: every metric this
machine reports, one row each, with a Gauge checkbox and a Chart checkbox.

The two columns are not symmetrical, and that is the one thing about the screen
worth explaining:

- **A gauge is per metric.** Tick Network In and Network Out and you get two
  dials, because a dial shows one number.
- **A chart is per group.** Tick both and you get *one* Network card with two
  lines, because in and out are only readable against each other. A group whose
  metrics are all unticked has no card at all rather than an empty one.

`LayoutPreferences` holds the two sets and lives in `MonitorCore`, so the merge
rules are testable without a window. It records which metrics it has an opinion
about as well as which are on: without that, a metric added by a later version
looks exactly like one somebody switched off, and would be silently missing.
`adoptingDefaults(for:)` gives an unseen metric its default and leaves every
choice already made alone.

Order is fixed, not derived. `LayoutDefaults.gaugeOrder` places the four dials
the app opens with, and anything else ticked goes after them by metric id;
`performanceGroupOrder` and `sensorGroupOrder` place the cards, with groups on
neither list — `Disk Ops`, `Network Packets`, `Memory Paging` — landing after
the named performance cards. A dial or a card that moves between launches is one
you have to hunt for.

The choices are written to `UserDefaults` under `wtf.evan.monitor`, named
explicitly rather than taken from `.standard`: `swift run monitor` has no
bundle, so `.standard` would give the development build its own domain and a
layout chosen in one build would be invisible in the other. Note what this is
not — the app still writes no *history* to disk and still does not link
`MonitorStore`. The argument in `storage.md` is about a sample every half second
forever, not about a checkbox written when somebody ticks it.

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

### The field is fixed at `xxxx.yy`

`Format.readout` right-aligns into four integer digits, a point, and two
decimals — `   4.23`, `  43.70`, `5012.66` — padded with blanks, never zeros
(`0004.23` reads as a part number).

The point never moving is the whole point. A readout you glance at is read partly
by *position*: if the point slides left as the value grows, `4.23` and `43.7`
occupy the same pixels with different meanings and you have to read all of it to
know which you are looking at. Nailed down, the shape of the number carries its
magnitude.

Four integer digits rather than three so the field cannot overflow on real
hardware — an internal SSD reads at around 5000 MB/s, which three digits could
not show at all. 9999.99 covers that and a 10 Gbit link, so the overflow pattern
(`----.--`, same width, so the display cannot jump) exists for completeness
rather than because anything reaches it. This is also why disk can stay pinned to
MB/s instead of switching to GB/s at the top end.

Three details are load-bearing:

- **Every cell reserves room for its decimal point**, lit or not, exactly as a
  physical part does. Claiming the space only when the point is lit would make
  `2.35` wider than `235`, and a readout that changes width as its value crosses
  a decade is the thing the display exists to prevent. The final cell is the one
  exception — a ghost dot with nothing after it reads as a lit point, turning
  `245` into `245.`.
- **A blank cell gets no ghosts.** A blank is a *position*, not a digit, and
  ghosting it draws a faint 8 where no digit is — so the three leading blanks of
  `   4.23` read as digits at a glance. The cell still claims its width, so the
  field stays fixed either way.
- **There is no `.contentTransition(.numericText())`.** `Canvas` draws
  imperatively from what its closure reads, so SwiftUI cannot interpolate
  between two readings. The value snaps, which is what an LCD does; the needle
  beside it carries the continuity.

The unit beneath the digits stays ordinary type, because "Mbit/s" is not
expressible in seven segments.

Six cells is most of the width of the dial face, which has two consequences.
The dial's **label sits under the dial** rather than on its face — at 130pt
across, "Network Out" on the face ran into the ticks — and it replaced the value
caption that used to sit there, which only repeated what the readout already
says. And the dial's end tick labels moved in to `0.54r`: at `0.62r` they ran
underneath the readout, and the fixed field is too wide to give the horizontal
room back, so they clear it vertically instead.

## Density: how much fits on screen

`Theme.Layout` gathers every size that decides how much of the dashboard is
visible at once, because they are one decision rather than eight.

What made only four cards visible was not card height — it was the **column
count**. A 380pt minimum card width in a 1156pt content area fits *two* columns,
so seven cards needed four rows. Halving that minimum gives four columns and the
same seven cards land in two rows. So the charts are barely shorter than they
were: the width came down by half, the height did not have to.

That distinction matters because the premise of the app is charts big enough to
read. Activity Monitor's are not, and shrinking far enough lands in the same
place — a literal half-of-both-dimensions left five cramped columns, legends
wrapped to `Tota l` and `Efficien cy`, time labels colliding into
`9:56:46 AM9:57:16 AM`, and a third of the window empty.

`chartMinimum` is the number to raise first if the density has gone too far,
since chart width is what the time axis needs. `chartMinHeight` is a *minimum*,
so a shorter window scrolls rather than squashing the charts — the right way
round: the charts stay readable and the window decides how many you see at once.

`chartMinHeight` later halved to 125pt, when the panel gained a second section.
Sensors sit below performance, and at the old height every sensor card was below
the fold — a chart you have to scroll to reach is one you stop looking at.

## Two sections, one rule between them

Performance above, sensors below, separated by the same 1pt rule that sits under
the gauges. What the machine is doing and how hot it is getting are read at
different moments and for different reasons, and in one grid the temperature
card is something you hunt for among the throughput cards.

The sensor section draws only what the machine reports and disappears entirely
on a machine that reports none of it, which is why it is `if !groups(in:).
isEmpty` rather than a fixed row: a fanless MacBook Air has no fans, and an
empty card under a rule is worse than no rule.

## Legends wrap; they do not shrink

A card's legend is the series' colour, name and current value, laid out with
`FlowLayout` — a `Layout` that packs entries left to right and wraps. An
`HStack` given less width than its children want compresses them instead, and a
compressed legend entry truncates: Memory's seven series in a four-column grid
became a row of coloured dots followed by ellipses, which is what prompted this.

Cards with more than three series put the legend on its own line so it gets the
card's full width rather than what is left beside the title. Two- and
three-series cards keep the compact single line, because spending a second line
of chrome on a Disk card that reads `Read 0.36 MB/s  Write 0.00 MB/s` buys
nothing.

## The gauge wall is resizable

The rule between the dials and the charts is a drag handle. Pull it down and the
dials grow to fill the space; pull it up and the charts take it back.

It is a handle rather than a constant in `Theme.Layout` because the right answer
changes with the session. Watching a restore run wants dials you can read across
the room; reading a memory trend wants the charts. Everything inside `GaugeView`
is a fraction of the dial's radius, so a dial dragged to three times the size
scales whole — ticks, redline, needle width, the seven-segment readout. Only the
caption under the dial is separate, and `Theme.Layout.gaugeCaptionSize` grows it
with the dial rather than in exact proportion, which would be shouting at 300pt.

Two details matter more than they look:

- **The drag is measured in the global coordinate space.** The handle sits
  *inside* what it resizes, so it slides down as the dials grow. A translation
  measured against its own moving origin reports the pointer's travel minus the
  handle's, which damps the drag to roughly half speed and feels like the panel
  is resisting.
- **The ceiling is the width, not a constant.** `Theme.Layout.gaugeMaximum` is a
  sanity limit; the real one is the largest dial that keeps every gauge on one
  row, which `DashboardView.gaugeCeiling` computes from the measured width. Past
  it the grid wraps and the wall grows by a whole row at once, which under a drag
  reads as the panel jumping rather than resizing. Narrowing the window
  re-clamps for the same reason.

The size is not persisted. v1 writes nothing to disk, and a dial size is not the
thing to make an exception for.

## A legend that does not shuffle

Each card's header carries the current value per series. Two things keep it
still while those values change:

- **Monospaced type**, so an individual digit does not change width as it
  changes value.
- **A slot pre-sized to the widest reading the unit can produce**
  (`Format.widestValue`), so the *number of* digits cannot move anything either.

`.monospacedDigit()` alone is not enough: it equalises digit widths but reserves
nothing, so `1%` and `100%` still occupy different space and every entry beside
them slides to make room. Measured on a CPU card, a series climbing from 1% to
100% used to move the first swatch 42px and the others 14–28px; with the slot
reserved, all three sit at identical pixel columns at every magnitude.

The reservation is a floor, not a cap — it is held by a hidden placeholder in a
`ZStack`, which takes the width of its widest child, so a reading wider than the
reservation grows the slot rather than being clipped. Getting `widestValue` wrong
costs a little jitter at an extreme, never a truncated number.

One shift this does not address: on a chart whose y-axis auto-scales, the axis
label width changes when the domain rescales (`0 MB/s` … `8 MB/s` versus
`0 MB/s` … `600 MB/s`), which moves the plot's left edge. That happens on a
rescale rather than on every sample, and fraction charts are pinned to 0–1 so
their labels never change at all.

## Which cards appear, and what they are bounded by

`LayoutDefaults` names the chart cards explicitly, in order, for the same reason
the gauge list is explicit: cards that move between launches are cards you have
to hunt for. It also carries two decisions that deriving the list could not
express — that disk and network throughput deserve a chart *as well as* a dial,
because a needle cannot tell you a transfer has been running for a minute; and
that `Disk Ops`, `Network Packets` and `Memory Paging` are diagnostic detail
belonging in `monitorctl` rather than on a dashboard you glance at. Both are
opening positions rather than verdicts: the Layout tab is where you disagree.

Two things bound a chart to its card:

- **Marks are filtered to the visible window.** Swift Charts does not drop marks
  that fall outside the x domain — it draws them anyway, outside the plot area
  and straight through the axis labels and the card's own edge. The buffer holds
  ten minutes and the window is usually one or two, so most of what it holds has
  to be filtered out before it reaches the chart. This is also nine-tenths less
  drawing.
- **`chartPlotStyle { $0.clipped() }`** catches what is left, since a sample can
  still sit fractionally outside the domain at either edge.

The y-axis scales to what is on screen, not to the whole buffer. Otherwise a
spike eight minutes off the left of a two-minute window flattens everything you
can actually see.

Axis labels use `Format.axisLabel`, which is coarser than the readout: `20 MB/s`
up the side rather than `20.0 MB/s` next to `0.00 MB/s`. An axis is a scale, not
a measurement, and the current value is spelled out in the card's header anyway.

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
