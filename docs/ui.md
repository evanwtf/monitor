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

Each group is a collapsible section, and its heading carries the same two
checkboxes one level up: they set every metric under it. They are built with
`Toggle(_:sources:isOn:)`, given the row bindings, so the three states come from
the rows rather than from a flag kept in step with them — on when all agree, off
when none, **mixed** when they disagree. The mixed dash is what keeps a folded
section readable: "some of these" is visible without unfolding it.

Collapsing is view state, not a stored preference. It is how you get a long list
out of the way while working on one group — a decision for the next thirty
seconds, not the next month — and a preferences window that opens half closed
hides the thing somebody came to find.

`LayoutPreferences` holds the two sets and lives in `MonitorCore`, so the merge
rules are testable without a window. It records which metrics it has an opinion
about as well as which are on: without that, a metric added by a later version
looks exactly like one somebody switched off, and would be silently missing.
`adoptingDefaults(for:)` gives an unseen metric its default and leaves every
choice already made alone.

## Arranging the panel

Order used to be derived: the dashboard recomputed it from the `LayoutDefaults`
constants on every access. Once a tile can be dragged, order is data, and
`PanelArrangement` is where it lives — also in `MonitorCore`, also testable
without a window.

Keep the two apart. **`LayoutPreferences` is what is drawn. `PanelArrangement`
is where it goes and how big it is.** Two structs and two preference keys, so a
value this version cannot read costs one of them and not both.

### Dragging

Drag a dial along the wall, or a chart card around the grid, to reorder it.

- **Insert-before, not swap.** For two adjacent tiles the two are the same
  gesture. For anything further apart, swap flings an unrelated tile across the
  panel into the space you just left, which is not what dragging something looks
  like anywhere else.
- **The drop target is half a tile.** The gap you are aiming at is the nearer
  one. Whole-tile targets leave the last position in a row unreachable, because
  there is nothing after it to drop before.
- **A dial and a card are different things**, and a drop target refuses the
  wrong one. `PanelTile` carries which, encoded as text behind a private prefix
  and parsed strictly, so foreign text dropped on the panel fails to parse and
  the move is refused.

The insertion line is an overlay on the neighbouring tile rather than a real
item in the grid. A placeholder item would reflow everything after it on every
frame of the drag, which is the panel rearranging itself under the pointer
before anything has been dropped. It is `allowsHitTesting(false)`, and that
matters — see below.

### Two traps this walked into

Both broke dragging completely while every test stayed green, so they are
written down rather than left to be rediscovered.

**A drop target must not be an overlay with a content shape.** The first version
put two `Color.clear` halves in an `.overlay` with `contentShape(Rectangle())`,
one per side, to tell leading from trailing. An overlay sits *above* the
content, so it swallowed the mouse-down and `.draggable` never saw a press —
nothing could be dragged at all. There is now one `DropDelegate` over the whole
tile that asks `DropInfo.location` which half it is in, and the width comes from
a background `GeometryReader`, which is not hit-testable.

**A custom `UTType` needs an `Info.plist` declaration, and `swift run monitor`
has no bundle.** The first version carried the payload as a private type via
`UTType(exportedAs:)`. Unbundled, the type went unregistered, no drop
destination ever matched it, and dragging did nothing in exactly the build the
development loop uses. A type that only works when packaged is a type that gets
broken between packages. The payload is plain text now, behind a prefix nothing
else produces.

### The rule between the sections

Cards can be dragged across it. The performance/sensor split keeps its defaults
but stops being a rule about what belongs where: if the pairing you care about
is CPU load beside CPU temperature, you can have it.

The section is drawn whenever the machine has sensors **at all**, not when the
section currently holds a card, and shows a drop zone when empty. Drag the last
sensor card up and the section has to stay, or there is nothing left to drag it
back to. A machine that reports no sensors still shows nothing.

### Sizes

The toolbar's Size button opens three sliders: gauges, chart width, chart
height. In the toolbar rather than in preferences for the same reason the
sampling rate is — you change it while watching, and judging a dial size in one
window while dragging a slider in another is guesswork.

**Gauges are one number**, because the dial is square. **Charts are two**: a
wide short card and a tall narrow one answer different questions, and neither is
a scaled copy of the other. The rule under the gauge wall is still a drag handle
and drives the same number as the first slider.

The bounds live in `PanelSize` in `MonitorCore` rather than in `Theme.Layout`,
because a stored size has to be clamped by the value type that holds it, and
bounds the type cannot see are bounds it cannot enforce. `Theme.Layout` forwards
to them, so views still read one place.

### What is written, and when

**Every gesture writes once, when it ends.** A slider dragged across its travel
fires on every frame, and a drag crosses several drop targets on the way to the
one it wants; persisting each change turns one decision into hundreds of writes.
So `AppModel.arrangement` deliberately has no saving `didSet`, unlike `layout`
beside it — a checkbox changes once when it is clicked, a drag does not. Mutate
it freely during a gesture and call `commitArrangement()` at the end.

Narrowing the window still shrinks the dials, so the row cannot wrap and
silently double the height of the wall. That is not committed: it is not a
request to keep smaller dials forever, so the chosen size comes back when there
is room for it.

### Where new things land

`LayoutDefaults` is the seed for the order rather than the order itself.
`adoptingDefaults(for:)` gives anything the arrangement has not seen a position
and moves nothing that already has one, so a sensor that appears when you plug
in a dock lands among its own kind rather than at the end.

It needs no `known` set, unlike `LayoutPreferences`. In a set of what is
switched on, "off" and "never heard of" are both absence; in a list of
positions, **not being in the list is what unknown means**.

Entries for metrics the machine no longer reports are kept. They draw nothing,
because the panel only draws what it has a descriptor for, and an external GPU
that comes back finds its old place waiting.

A dial switched off keeps its position too, so switching it back on returns it
to where it was rather than appending it to the end of the row.

`AppModel.groupOrder` feeds the preferences list, so it reads the arrangement as
well. The list and the window it configures have to agree about where things
are; leaving that one on the `LayoutDefaults` constants is how this breaks.

The choices are written to `UserDefaults` under `wtf.evan.monitor`, named
explicitly rather than taken from `.standard`: `swift run monitor` has no
bundle, so `.standard` would give the development build its own domain and a
layout chosen in one build would be invisible in the other. Note what this is
not — the app still writes no *history* to disk and still does not link
`MonitorStore`. The argument in `storage.md` is about a sample every half second
forever, not about a checkbox written when somebody ticks it.

## Mirrored in/out charts

Network In and Network Out share a card so they can be read against each other,
and drawn both upward from zero they overlap: at a glance you cannot tell which
trace is which without reading the legend.

Switch **Mirror paired charts** on in the Charts tab and one direction goes
above the baseline, the other below. Zero moves to the middle of the plot.
Upload and download become two shapes that cannot be confused, and the shape of
a transfer — a burst up, a long tail down — is readable without reading the key.

Five cards are pairs: Network, Network Packets, Disk, Disk Ops and Memory
Paging. Inbound above outbound in every case — in above out, read above written,
page in above page out — because the first is the one that arrives, and download
above upload is how every meter of this kind has drawn it since modem lights.

### Only the picture flips

The sample in the buffer stays positive. A rate is never negative, and a
negative must not reach the formatter, the gauges, or the CSV export — `plotted`
in `ChartCard` negates at draw time and nothing else knows. The axis labels read
as magnitudes on both sides too: below the line is a *direction*, not a negative
quantity, and `-50 MB/s` is not a rate anything can achieve.

### One shared scale

The domain is symmetric about zero, and its half-range is the larger of the two
peaks. So a card where download dwarfs upload looks nearly flat on the quiet
side. That is honest, and it is the whole reason the two share a card: a scale
per direction would make a 30 kbit/s upload and a 300 Mbit/s download draw the
same shape.

### Both halves or neither

`ChartMirror.pair(for:)` returns a pair only when the card draws exactly the two
metrics of one. Switch Network Out off in the Layout tab and the card stops
mirroring rather than leaving a single trace hanging below an empty top half,
which reads as a bug rather than as a choice.

### Pairing is declared, not tabulated

A metric says which way it runs. `MetricDescriptor.direction` is `.inbound`,
`.outbound`, or nil for the great majority that are not one direction of
anything. A card is a pair when it draws exactly one inbound series and one
outbound one, so there is no table of metric ids anywhere and a source added
later gets mirroring without this being told it exists.

The first version *was* a table, on the reasoning that "this one points down" is
a statement about a picture and a disk reader has no business making it. That
reasoning was right about the wrong thing: which way a byte is travelling is a
fact about the metric, and only the decision to draw one below a line is about
the picture. The fact belongs on the descriptor; the picture stays in
`ChartPreferences`.

Read and write *latency* are the instructive case. They share a card and look
like a pair, and neither declares a direction, so the card never mirrors — two
measurements of the same kind are not two directions of one flow, and drawing a
slow write below the line would say a slow write is the opposite of a slow read.

Two tests hold the declaration together: every group that declares a direction
must have exactly one metric of each, checked against the real registry in
`MonitorSourcesTests`. A group with an inbound metric and no outbound one can
never mirror, which is a declaration somebody half finished rather than a
choice.

`ChartPreferences` is its own type beside `LayoutPreferences` for the matching
reason: **`LayoutPreferences` is which cards exist, `ChartPreferences` is how one
is drawn.** Separate keys, so a value a later version writes costs one and not
both. It saves on change, like the layout and unlike the arrangement — a
checkbox has no gesture to end.

Off by default. Mirroring is the clearer way to read throughput, but a chart
that changes shape under somebody on upgrade is worse than one they switch on.

## Stacked cards

Memory is not seven independent readings. App, wired, compressed, cached and
free are five slices of one machine's RAM, and drawn as five lines from zero
they answer "how big is each part" while hiding the question you opened the card
for: how full is the machine. Stacked, the bands answer both — each band is a
part, the top of the stack is the total.

Switch **Stack the parts of a whole** on in the Charts tab. Today that is Memory
and CPU; anything declared later joins them.

### A metric says whether it is a slice

`MetricDescriptor.composition` is `.part`, `.aggregate`, or nil. Same shape as
`direction`, and for the same reason: it is a fact about the metric, so a source
added later gets stacking without anything else being told.

- **`.part`** — one slice of the group's whole. Slices do not overlap.
- **`.aggregate`** — a sum of slices in the same group. Memory Used is app plus
  wired plus compressed; CPU Total is user plus system.
- **nil** — neither. Memory Swap shares the card and is not in the machine's RAM
  at all, and two temperature sensors are two readings rather than a division of
  anything.

A card stacks when it draws **two or more** slices. One band is an area chart
with extra steps.

### An aggregate must never be a band

This is the trap the whole feature turns on. Memory Used is app plus wired plus
compressed, so stacking it counts those three a second time and puts the top of
the card at nearly twice the RAM in the machine. It keeps its line instead,
where it lands exactly on top of the bands it sums — which reads as a check
rather than a contradiction.

`MonitorSourcesTests` holds the claim against the real machine: the slices
account for between 85% and 102% of physical RAM, so they cannot be overlapping,
and Used is strictly larger than any one of them. CPU is an exact identity —
user plus system *is* total, to four decimal places.

### Lines among bands are dashed

A line on a stacked card is a different kind of statement and has to look like
one. Solid strokes are what the card uses for slices, so an aggregate or an
unrelated series drawn solid invites reading it as one more slice. Dashed, with
a hollow legend swatch instead of a filled one, so the key says what the chart
says.

### The scale is the stack's height

A stacked card's y-axis is bounded by the summed height per timestamp, not by
the tallest single band. The top of the stack is what the eye reads, and scaling
to one band would push the stack out through the top of the card. Memory has a
`nominalMaximum` of physical RAM so it was already bounded; a stacked group
without one would not be.

### Stacked and mirrored are exclusive

Two directions of a flow are not slices of a whole, so nothing declares both and
a registry test proves it. `ChartCard` drops the stack when a mirror is set as
well, because a band drawn below a baseline would be nonsense however it got
there.

## The time axis

Three things have to be true of the labels along the bottom, and the first two
versions of this got one of them at the expense of another.

**A tick is an instant, not a position.** 10:42:00 belongs at 10:42:00. As the
window scrolls that gridline travels left, keeps its label, and eventually
leaves. Ticks placed at fractions of the window do the opposite: the gridline
stands still while the time under it counts up in real time, which is a clock,
not an axis.

**Never more labels than fit.** `.automatic(desiredCount:)` treats the count as
a hint and chooses its own boundaries, so on the narrowest column the grid makes
the labels collided and the last one ran off the edge as `10:34…`.

**Never fewer than two.** One lonely label says nothing about the span you are
looking at, and none says less.

`ChartAxis` in `MonitorCore` holds the arithmetic, which is why it is testable
without a window.

### The interval comes from the window's length, never its position

The ticks are absolute instants, so how many land inside the window depends on
where the window happens to sit — the same interval yields three, two, one or
none as it slides. An early version chose the interval by counting what it
actually produced, which meant a narrow ten-minute card flipped between 300 s
and 120 s every few seconds and the labels jumped between two and five.

So the interval is chosen from the length alone: the coarsest rung of the ladder
(1, 2, 5, 10, 15, 30 s, then 1, 2, 5, 10 min) that fits two of itself in the
window, or a finer one where the card has room for more. The count still drifts
by one as a tick scrolls off the edge, which is correct and invisible. The
interval does not move.

Where the two rules conflict — a narrow card showing five minutes cannot have
both two labels and no more than two — **two labels win**. A bare axis is worse
than a tight one.

### Details

Ticks are held 6% in from each edge, because a label is centred on its tick and
one against the edge is half cut off. A tick inside that band is dropped rather
than nudged: moving it would put it somewhere that is not the time it claims.

Seconds appear only when the interval is under a minute, where two labels would
otherwise land inside the same minute and read as the same time twice.

No AM/PM at any width. A card shows ten minutes of history at most, so which
half of the day it is was never in question, and those two characters were most
of what made the labels collide.

## Title and legend: fit, not count

A card puts its legend beside the title when it fits and underneath when it does
not, and `ViewThatFits` decides by proposing the column's width.

It used to decide by counting series, which cannot work: a count does not know
how wide the words are. "Memory Paging" beside "Page in 19/s  Page out 4.0/s" is
two series and does not fit; "GPU" beside "GPU 0%  VRAM 1.9 GB" is two series
and does. The title is `fixedSize` — it must not truncate — so a header that did
not fit pushed the card wider than its grid column, which stretched the whole
row and ran the legend out through the card's edge.

## Copying a card

Right-click any tile — a chart card or a dial — for two items.

**Copy Image** puts the tile on the pasteboard as a PNG. It is rendered on its
own with `ImageRenderer` rather than captured from the window, so what you get
is the card and nothing around it: no insertion indicator left over from a drag,
no slice of the panel behind it. The scale is the screen's own, or a copy of a
Retina card arrives looking like a photograph of one. It is padded and drawn on
the panel background, because a dial draws no background of its own and a
transparent needle lands invisible in half the places you would paste it.

**Copy Data** puts the samples behind the card on the pasteboard as CSV. Two
rules shape it, both in `CSVExport` in `MonitorCore` — the interesting part is
the row alignment and the choice of units, and neither needs a window to test.

### Copy what the picture showed

The buffer holds ten minutes and a card usually shows one or two. The export is
cut to the same window the chart is drawing, so the numbers and the picture
agree. Copying the whole buffer would hand back data that was never on screen.

### Copy what was stored, not what was drawn

The panel pins disk to MB/s and network to Mbit/s, because the unit under a
needle must not change while you are reading it. A spreadsheet has no needle,
and a divided number is a number somebody has to undo. So the CSV carries what
the buffer holds — bytes per second, bits per second, and a fraction between
zero and one — and the header names the unit:

```
Time,Disk Read (B/s),Disk Write (B/s)
2026-08-18T14:32:10-04:00,5000000.0000,120000.0000
```

`Format.baseUnit` is that table, and it is deliberately *not* `Format.unitLabel`
beside it. A column headed `MB/s` carrying bytes is the quiet kind of wrong the
whole formatting file exists to prevent.

One row per timestamp, oldest first, with every series on it. A series that
missed a tick leaves its field **empty rather than zero** — a skipped source is
not a source reading zero, and a spreadsheet that cannot tell them apart draws
exactly the lie the panel refuses to draw.

Values are written with fixed decimals rather than Swift's shortest round-trip,
which spells small numbers `1e-05` — a valid double, and text to some
spreadsheets.

### The gauge gets the same menu

A dial shows one number, but the buffer behind it holds the same history a chart
has, so **Copy Data** on a gauge gives that one metric over the same window.
Every tile has the same two items; a menu that changed shape between tile types
would be one more thing to remember.

### Nothing is written to disk

The pasteboard is somewhere the user asked for it to go, once, by choosing a
menu item. `MonitorStore` stays unlinked and the ring buffer stays in memory.

## Zooming one tile

The panel is a wall of tiles sized to be glanced at. When one of them is the
reason you opened the app you want it big, and the size sliders are the wrong
tool: they resize *every* card, and they have to be put back afterwards.

**Double-click a tile to zoom it. Escape, Done, or another double-click closes
it.**

### It is a mode, not a property

One `@State` value on the dashboard holds the zoomed tile. Opening a second one
therefore closes the first by construction, rather than by anybody remembering
to close it. It is `@State` and not `PanelArrangement` because a zoom must not
survive a relaunch and must not resize anything stored — the tile comes back the
size it was.

### A sheet, not a second window

Three answers were on the table: a sheet over the panel, the card expanded in
place, or a real second window.

A sheet won. It is temporary in a way the other two are not — Escape already
means dismiss, and there is nothing left over to find later. A second window
raises questions this app has not had to answer: its own toolbar, its own
history window, whether it survives a relaunch. Expanding in place keeps the
toolbar reachable, which the sheet does give up, but it leaves the panel in a
state that looks like a bug if you walk away from it.

The sheet costs one thing and buys one thing, and the trade is deliberate.

**Nothing stops sampling while the zoom is open.** The buffer is shared, so the
panel underneath keeps filling and comes back without a gap.

### Three gestures on one tile

A tile now carries a left-drag to reorder, a right-click to copy, and a
double-click to zoom. They do not fight: `.draggable` claims the press only once
the pointer moves, the context menu is a separate button, and a count-2 tap
gesture leaves both alone. This is checked by running the app, not by a test —
gesture conflicts do not show up in a green suite.

### Sizes

`ZoomLayout` turns the panel's size into the sheet's. The zoom is 86% of the
panel's width and 82% of its height, bounded to 520×360 at the small end and
1400×900 at the large one. The margin of panel left showing is what says this is
a temporary thing over the dashboard rather than a screen you navigated to; the
upper bound is where a zoom stops being reading a chart and starts being
stretching one. What is left after the title bar and the card's header is the
plot, floored at the smallest chart height the panel itself allows.

### Not in scope here

A zoomed chart has room for more than a bigger version of the same picture: more
x-axis labels, and a longer history window than the panel's. Neither is done —
the zoom draws the same card the panel does, at a larger size.

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
