# monitor

## Overview

A standalone macOS system monitor: CPU, GPU, memory, disk and network, in a
window with charts big enough to read. **Not a menu-bar extra.** Activity
Monitor is the closest thing in the right direction, and the two things wrong
with it are the two things this exists to fix — the charts are too small to read
and the history starts when you open the app.

**v1 is realtime and writes nothing to disk.** History lives in a ring buffer in
memory and dies with the process. That is a deliberate scope decision, not an
oversight. Persistence and a background sampler come later — see
`docs/roadmap.md`.

## Tech Stack

- Swift 6 (`swift-tools-version: 6.0`), SwiftPM, macOS 14+. No third-party
  dependencies.
- SwiftUI, Swift Charts, `Canvas` for the gauges.
- System APIs: mach (`host_processor_info`, `host_statistics64`), IOKit
  (`IOBlockStorageDriver`, `IOAccelerator`), `getifaddrs`, `sysctl`,
  SystemConfiguration (`SCNetworkInterfaceCopyAll`).
- Tests use swift-testing (`@Suite`, `@Test`, `#expect`), not XCTest.
- swiftformat (`.swiftformat`) for lint. CI runs on a self-hosted macOS ARM64
  runner.
- Logging is `os.Logger` via the package-wide `log` in `MonitorCore/Log.swift`
  (subsystem `wtf.evan.monitor`). Only `monitorctl` prints, because printing is
  its output.

## Environment & Dependencies

- A Mac running macOS 14 or later with a Swift 6 toolchain. Nothing else — the
  package resolves no dependencies, so there is no install step.
- `swiftformat` must be on `PATH` for the lint gate. CI installs it with
  `brew install swiftformat` when it is missing.
- `MonitorSourcesTests` read the real machine, so they need a real Mac. They
  assert plausible ranges, not values, and pass whatever the machine is doing.

## Commands

```sh
swift build && swift test        # build + full suite
swift test --filter GaugeScale   # one suite or test
swift build -c release           # CI also gates the release build
swift run monitor                # the app — the fast dev loop, no Xcode needed
swift run monitorctl list        # every source and the metrics it declares
swift run monitorctl read        # read every metric once
swift run monitorctl watch --source disk --interval 0.5
swift run monitorctl watch --json --count 5        # machine-readable, bounded
swift run monitord --retention 7d --dir /tmp/logs  # rotating CSV logger
swiftformat Sources Tests Plugins --lint --cache ignore   # CI lint gate
Scripts/make-app.sh [dest]       # wrap the release binary in monitor.app
Scripts/make-icon.swift out.icns # draw the app icon (make-app.sh calls this)
Scripts/notarize.sh app zip      # notarize a Developer ID build and staple it
```

`monitorctl` exists because sampling is the part most likely to be wrong and the
GUI is the worst place to find that out. Work on a source through the CLI, then
look at it in the app.

## Project Layout

```
Sources/
  MonitorCore/     metric model, ring buffer, downsampling, gauge auto-ranging,
                   seven-segment digit mapping, formatting, the sampling clock,
                   the layout, arrangement, chart and sampling preference
                   models, CSV export, chart axis ticks. No macOS APIs — so all of it is testable
                   without a machine to read.
  MonitorSources/  the readers: CPU, memory, disk, network, GPU, SMC sensors
                   (temperature, fans, power), and the registry that lists them.
                   One file per source, plus SMC.swift for the SMC transport.
  MonitorUI/       Theme (palette + Layout density), GaugeView, SevenSegmentText,
                   ChartCard, FlowLayout, DashboardView, PreferencesView,
                   SizePopover, ReorderDrag (drag-to-reorder for both grids),
                   CardExport (right-click to copy a card), AppModel,
                   LayoutPreferencesStore (layout, sampling, arrangement)
  MonitorStore/    SQLite history and retention. Designed and tested but NOT
                   linked into the app — see "Guardrails" below.
  MonitorLog/      the rotating CSV logger: CSVLogSink. Written by monitord;
                   never linked into the app.
  monitor/         the app target (@main SwiftUI App) and its AppDelegate
  monitorctl/      headless CLI harness
  monitord/        headless daemon that logs every metric to rotating CSV
Plugins/
  StampCommit/     prebuild plugin: writes the commit into a Swift constant
                   before every build, so the title bar cannot go stale
Scripts/           make-app.sh, which builds monitor.app, make-icon.swift,
                   which draws its icon, and notarize.sh, which notarizes and
                   staples a Developer ID build
Tests/             MonitorCoreTests, MonitorSourcesTests, MonitorStoreTests,
                   MonitorLogTests, MonitorUITests
docs/              README.md is the index
.github/workflows/
  ci.yml           build, test, release build, CLI smoke test, lint
  release.yml      bumps the version on a merge to main, tags it, releases it
  package.yml      reusable: builds monitor.app, zips it, attaches it to a tag
```

One SwiftPM package: one build and one test command cover all of it, so there
are no component-level AGENTS.md files.

## Key Concepts

- **`MetricID`** is a stable string key. It is the on-disk key for stored
  history, so renaming one orphans its data.
- **`MetricDescriptor`** is what the UI needs to draw a series — name, group,
  unit, kind — without knowing which source produced it. Cards are laid out by
  `group`.
- **Counter vs gauge**: disk, network and paging report cumulative totals since
  boot. `RateTracker` differentiates them. It returns nil for the first reading
  of a series on purpose, because there is no rate yet and reporting zero would
  draw a dip that did not happen.
- **`GaugeScale`** auto-ranges a dial and snaps full scale to a `ScaleLadder` —
  1-2-5 by default, decades for the throughput dials. It rises immediately and
  falls slowly, stepping down only once the value has stayed clear of the next
  scale down for a continuous `decayInterval`.
- **Throughput units are pinned.** Disk is always MB/s, network always Mbit/s,
  at every magnitude, and the gauge readout is a fixed `xxxx.yy` field whose
  decimal point never moves — the unit under a needle must not change while you
  read it. Network converts bytes to bits *in the source*, so the dial, the
  chart axis and `monitorctl` cannot disagree.
- **Network counts physical NICs only** — Wi-Fi and wired, via
  `SCNetworkInterfaceCopyAll` filtered to the Ethernet and IEEE80211 types, and
  re-resolved every 10 s so a dongle appears. Summing every `getifaddrs`
  interface double-counts a VPN's traffic and adds AirDrop and Apple's internal
  interfaces on top.
- **CPU load is per cluster, not per core.** One series per `hw.perflevel`,
  keyed by level because the *name* differs across silicon ("Super" on M4,
  "Performance" earlier). `host_processor_info` numbers cores in reverse
  perflevel order — slowest cluster first.
- **Gauges are for rates, charts are for levels.** A dial answers "how hard is
  this working right now against what it can do" (disk, network throughput). A
  chart answers "what has been happening" (CPU, memory). `LayoutDefaults`
  encodes the split — but as an opening position, not a rule.
- **The panel is arranged by dragging, and stored.** `PanelArrangement` (in
  `MonitorCore`) holds where every tile sits and how big tiles are; the order
  used to be recomputed from `LayoutDefaults` on every access, and those
  constants are now the **seed** for it rather than the order itself. Keep the
  two apart: **`LayoutPreferences` is what is drawn, `PanelArrangement` is where
  it goes.** Two structs, two preference keys. Reordering is insert-before
  rather than swap, the drop target is half a tile so the last position in a row
  is reachable, and a card can be dragged across the section rule — the
  performance/sensor split is a default, not a rule about what belongs where.
  The drag payload is plain text behind a private prefix, **not** a custom
  `UTType` — see Troubleshooting for why.
  The sensor section is drawn whenever the machine has sensors *at all* rather
  than when it holds a card, so dragging the last one out does not remove the
  target needed to drag it back.
- **Every gesture writes once, when it ends.** `AppModel.arrangement`
  deliberately has no saving `didSet`, unlike `layout` beside it: a checkbox
  changes once when clicked, but a slider fires on every frame of a drag and a
  drag crosses several drop targets on the way to the one it wants. Mutate it
  freely during a gesture, then call `commitArrangement()`. Adding a `didSet`
  that saves would turn one decision into hundreds of writes — the thing
  `docs/storage.md` exists to prevent.
- **A metric declares which way it runs.** `MetricDescriptor.direction` is
  `.inbound`, `.outbound`, or nil for everything that is not one direction of a
  flow. Five groups pair up: Network, Network Packets, Disk, Disk Ops, Memory
  Paging. Read and write *latency* deliberately declare nothing — two
  measurements of the same kind are not two directions of one flow. A group
  that declares a direction must declare its opposite too, checked against the
  real registry in `MonitorSourcesTests`.
- **A metric declares whether it is a slice of a whole.**
  `MetricDescriptor.composition` is `.part`, `.aggregate` or nil. Memory (app,
  wired, compressed, cached, free) and CPU (user, system) are slices; Memory
  Used and CPU Total are the sums of them; Memory Swap is neither, being on
  disk. **An aggregate must never be stacked** — Used is app plus wired plus
  compressed, so a band for it counts those three twice and puts the top of the
  card at nearly twice the machine's RAM. It keeps a line, which lands on top of
  the bands it sums. Lines on a stacked card are **dashed**, with a hollow
  legend swatch, because a solid stroke among bands reads as one more slice. A
  card stacks only when it draws two or more slices, and its y-axis is bounded
  by the **summed** height rather than the tallest band. `MonitorSourcesTests`
  holds the claim against the real machine: the slices account for 85–102% of
  physical RAM, so they do not overlap. Nothing is both a slice and a direction,
  and a registry test proves it.
- **Paired charts can be mirrored, and only the picture flips.** Inbound draws
  above the baseline and outbound below it when **Mirror paired charts** is on
  in the Charts tab. The stored sample stays positive — a rate is never
  negative — so `ChartCard.plotted` negates at draw time and the legend, the
  formatter, the gauges and the CSV export are untouched. Axis labels are
  magnitudes on both sides. One symmetric scale, not one per direction: the two
  share a card in order to be read against each other. A card mirrors only when
  it draws **both halves**, so switching one direction off returns it to drawing
  upward rather than leaving a trace under an empty top half. `ChartPreferences`
  is its own type and key beside `LayoutPreferences`: **which cards exist**
  versus **how one is drawn**. Off by default, because a chart that changes
  shape on upgrade is worse than one somebody switches on.
- **A rate can be totalled, and the sum is already in the buffer.** **Show
  totals for the window** in the Charts tab puts how much moved beside how fast
  it is moving. A rate sample *is* the mean over the gap before it, so
  `Σ(rate × preceding gap)` telescopes back to exactly the counter delta —
  `WindowTotal` in `MonitorCore` is that sum, and it keeps no counter history,
  changes no source and writes nothing. Three things it must keep doing: report
  **`covered` beside `value`**, because "2 min" over ten seconds of history is
  the quiet kind of wrong; **clip an interval wider than `maximumGap`**, or a
  laptop back from sleep credits one sample with an hour of traffic that never
  crossed the wire; and return **nil under two samples**, not zero, the same
  answer `RateTracker` gives on a first read. `MetricUnit.accumulation` says
  what a unit adds up to and is nil for every level — derived from the unit like
  `direction` and `composition`, never a table of ids. **Network totals in
  bytes** while its rate stays Mbit/s: a link is quoted in bits, a volume in
  bytes, and the divide by eight has one definition. The card totals `series`,
  not `visible` — the sum needs the sample just outside the window's left edge
  to measure the interval straddling it. `AppModel.totalGap` is four ticks of
  the master clock, so it follows the Sampling tab rather than assuming 0.5 s.
  **A card with totals draws a `Grid`, not a `FlowLayout`** — swatch, name,
  rate, total, with the totals column headed and **right-justified**, because a
  magnitude is read by where its last digit sits and wrapped entries put them at
  four different left edges. It sits under the title, never beside it:
  `ViewThatFits` is the right question for a wrapping row and the wrong one for
  a column of figures. Cards with nothing to total keep the flow. The reserved
  slot survives into the table — a `Grid` column sizes to its widest cell, so
  without it the column resizes whenever a total crosses a magnitude.
- **The time axis is computed, not automatic.** `ChartAxis` in `MonitorCore`.
  Three rules, and the first two versions traded one for another: a tick is an
  **instant** (10:42:00 sits at 10:42:00 and scrolls left keeping its label —
  ticks at fractions of the window stand still while their labels count up in
  real time); never more labels than fit; and **never fewer than two**, which
  wins where it conflicts with the second. The interval is chosen from the
  window's **length alone, never its position** — the count drifts by one as a
  tick scrolls off, but an interval chosen by counting actual ticks flips
  between rungs as the window slides and the axis restyles itself every few
  seconds. No AM/PM, and no leading zero on the hour; seconds only when the
  interval is under a minute.
  **Rule 2 now wins over rule 1**, which reverses the original order: labels
  that collide are unreadable, which is worse than the sparse axis the old rule
  avoided. Three things had to be right together, and getting one wrong put
  four overlapping labels on a card with room for two. The room is the **plot**,
  read from `chartBackground`'s proxy — never `chartOverlay`, which would
  swallow a tile's drag; a flat allowance for the y-axis is wrong on exactly the
  cards whose numbers are longest. Each stride is costed at the width of **its
  own** labels, because a stride of a minute or more shows no seconds and needs
  a third less room. And the widths are **measured**, not estimated — 32 points
  with seconds, 20 without, 10 rotated. **Turn the time labels sideways** in the
  Charts tab is how a narrow card gets both the fit and the two labels: rotated,
  a label costs its line height instead of its width. `rotationEffect` turns the
  glyphs and not the layout, so it needs `fixedSize` and then a frame, or the
  axis reserves no height and the text draws over the chart.
- **A card's header fits, it does not count.** Title beside legend when it fits,
  stacked when it does not, decided by `ViewThatFits`. A count of series cannot
  know how wide the words are, and since the title is `fixedSize` a header that
  did not fit pushed the card past its grid column and stretched the row.
- **A card can be copied, and the copy is not what the panel shows.**
  Right-click any tile for **Copy Image** (the tile rendered on its own with
  `ImageRenderer`, not captured from the window) and **Copy Data** (the visible
  window as CSV). `CSVExport` lives in `MonitorCore` so the row alignment and
  the units are testable. Two rules: the export is cut to the window the card is
  *drawing*, not the whole ten-minute buffer; and it carries **base units** —
  `Format.baseUnit`, not `Format.unitLabel`. The panel pins disk to MB/s and
  network to Mbit/s so the unit under a needle cannot move while you read it,
  but the buffer holds bytes and bits, and a column headed `MB/s` carrying bytes
  is the quiet kind of wrong. A series that missed a tick leaves an **empty
  field, never a zero** — same reason a failed source greys a card out instead
  of drawing a flat line.
- **A tile zooms in a sheet, and the zoom is view state.** Double-click any card
  or dial for a temporary window over the panel; Escape, Done or another
  double-click closes it. One `@State` value on `DashboardView` holds it, so
  opening a second tile closes the first by construction. It must **never** go
  into `PanelArrangement` — a zoom does not survive a relaunch and does not
  resize anything stored. Sizes come from `ZoomLayout`, a fraction of the
  measured panel, bounded at both ends. Sampling does not stop while it is open;
  the buffer is shared, so the panel underneath comes back without a gap. A tile
  now carries three gestures — drag to reorder, right-click to copy,
  double-click to zoom — and that they do not fight is checked by running
  `swift run monitor`, never by a test.
- **The layout is chosen per metric, in preferences.** Cmd-, opens a tabbed
  window. Its **Charts** tab holds how cards are *drawn* — stacking, mirroring,
  totals — which is a different question from which cards there are. Its **Layout** tab lists
  every metric with a Gauge checkbox and a
  Chart checkbox, grouped into collapsible sections whose headings carry the
  same two checkboxes for the whole group. The two columns are not symmetrical:
  **a gauge is per metric, a chart is per group.** Ticking Network In and Network Out gives two dials and *one*
  Network card with two lines, because in and out are only readable against each
  other. `LayoutPreferences` (in `MonitorCore`, so the merge rules are testable)
  tracks which metrics it has an opinion about as well as which are on —
  otherwise a metric added by a later version is indistinguishable from one
  somebody switched off, and stays silently missing. Its **Sampling** tab sets
  the two rates: performance and sensors.
- **One clock, but not one rate.** `Sampler.tick(at:)` reads every source at
  one timestamp so a batch lines up on the x-axis. A source that throws is
  logged and skipped for that tick only. `AppModel` samples at 0.5 s into a
  1200-point ring buffer — ten minutes of history, all of it in memory.
  A source that cannot produce a new value that often declares a
  `minimumInterval` and is read on every *n*th tick of the same clock, never on
  a timer of its own: its samples must land on the same timestamps as
  everything else. `SMCSource` declares 1 s because the SMC refreshes at 1 Hz,
  measured — see `docs/sensors.md`. **A skipped source is not a failed one**:
  `ingest` must exclude it from the unavailable set, or its cards grey
  themselves out on every tick in between.
- **Sensors are found, not assumed.** `SMCSource` scans the SMC's key table at
  launch and declares a metric only if this machine publishes sensors for it —
  so a fanless Mac shows no Fans card rather than one reading zero, and an Intel
  `TC0P` feeds the same CPU metric as Apple silicon's `Tp01`. Everything it
  reads is unprivileged; root is needed only to *write* a key, which it cannot.
  `docs/sensors.md` is the survey of what a Mac exposes and what it costs.
  **How many keys a family has is wildly model-dependent** — 84 GPU sensors and
  23 CPU ones on a 16-inch MacBook Pro, none of it predictable from the model
  name — so never hard-code a count or a list per model, and never sample a
  subset of a family whose metric claims to be the hottest of it.
- **The panel has two sections.** Performance above the rule, sensors below.
  The sensor section vanishes on a machine that reports none of it.
- **Releasing is a merge, nothing else.** `release.yml` bumps
  `MonitorVersion.string` itself on every merge to main, commits it back as
  `Version x.y.z [skip ci]`, tags it, publishes the release and attaches
  `monitor-<version>.zip` built by `package.yml`. **Never remove the
  `[skip ci]`** — it is what stops the workflow triggering itself into an
  endless bump.
  - **The default is a patch bump.** `release:minor` or `release:major` on the
    pull request says otherwise, so the size of a release is decided in review
    rather than remembered at merge time. Labels rather than Conventional
    Commit prefixes, because the commit style here is prose.
    **The label is read from the number in the merge commit's subject**, not by
    asking GitHub which pull request a commit came from — that association is
    not reliably present when this runs, and an empty answer is
    indistinguishable from an unlabelled merge. The lookup has no `|| true`
    either: it must fail loudly rather than fall through to the default.
    `permissions:` must keep `pull-requests: read`, since the block sets every
    scope it does not name to `none`.
  - **Two ways to publish nothing:** a `release:skip` label, or a merge that
    touched only `docs/`, `.github/` and top-level `*.md`. A merge touching
    docs *and* code still ships.
  - **Two escape hatches:** a pull request that sets `MonitorVersion.string`
    itself ships exactly that version, and a release published by hand from the
    GitHub UI gets its zip the same way.
- **Signing is off until two repository variables are set.** `SIGN_IDENTITY`
  and `NOTARY_PROFILE` turn on Developer ID signing and notarization in
  `package.yml`; unset, a release is ad-hoc signed exactly as before. Set,
  failing to sign or notarize fails the release rather than publishing a zip
  nobody can open. The credentials live in the Mac runner's keychain, not in
  GitHub secrets — which is why the runner's LaunchAgent needs
  `SessionCreate = false`: with the default `true`, every job gets its own
  security session, cannot reach the login keychain, and `codesign` fails with
  `errSecInternalComponent`. A signing runner cannot be headless.
  **`notarize.sh` rebuilds the zip after stapling** — `stapler`
  writes into the bundle, not the archive, so the uploaded copy is unstapled
  until it is made again. `docs/signing.md` is the setup.
- **The title bar says which build this is.** The app's name with
  `BuildStamp.label` under it — the commit and when it was made — as one block,
  **white on black in the system font**, with the window's own title removed
  (`toolbar(removing: .title)`, gated: the `.title` kind is macOS 15, so 14 gets
  an empty `navigationTitle`) so the name is not drawn twice. The `Window` scene
  keeps its real name for the Window menu and the Dock, and that name lives
  beside the version in `MonitorVersion`. **The trailing controls need
  `.primaryAction`, not `.automatic`** — they used to be pushed right by the
  title taking the slack in the middle, and removing it packed them up against
  the stamp. The styling is deliberately not the panel's palette or the cards' monospaced face.
  It is the one thing in the window that is not a reading: everything else is a
  measurement styled to be scanned, and this is a label on the photograph, there
  to survive being screenshotted and read back later. macOS 26 wraps toolbar
  items in a shared glass capsule, which made it dark-on-light and clipped it,
  so the item opts out with `sharedBackgroundVisibility(.hidden)` (gated to 26,
  additive — earlier releases add no capsule) and paints its own. `fixedSize`,
  because a commit truncated to look complete is worse than no stamp. **The two halves are sourced differently on
  purpose.** The commit is stamped at build time by the `StampCommit` prebuild
  plugin (`git describe --tags --always --dirty`), because a running program has
  no other way to know it and a checked-in constant is one somebody has to
  remember to update. The build time is read at *runtime* from the executable's
  own modification date — stamping it too would rewrite a source file on every
  build and recompile `MonitorCore` every time, which is the fast `swift run`
  loop gone for a fact the filesystem already has. **Keep `-dirty`**: a build
  with uncommitted changes is not the commit it names. The plugin writes its
  output only when the hash changes, for the same incremental-build reason, and
  falls back to `unknown` where there is no git — a source tarball, say. Lint
  covers `Plugins` too: `swiftformat Sources Tests Plugins`.
- **The version lives in `MonitorCore/Version.swift`.** The About panel reads
  it at runtime and `make-app.sh` greps that file when it writes `Info.plist`,
  so a bundled build and `swift run monitor` cannot claim different versions.
- **The icon is drawn, not stored.** `Scripts/make-icon.swift` renders it from
  the same palette as `Theme.swift` and pipes the set through `iconutil`, so
  `.build/AppIcon.icns` is a build product and no binary blob is in the
  repository.
- **A missing sample means unavailable.** `AppModel` marks any descriptor that
  produced no sample this tick, minus the first-tick warm-up for rate metrics.
  That is how a card gets greyed out instead of drawing a flat zero line.

## Code Style & Patterns

- Follow `.swiftformat`: 4-space indent, 96-column soft limit, no `self.` unless
  required, `0..<n` ranges.
- A source is one file, conforms to `MetricSource`, declares its descriptors up
  front, and is added to `SourceRegistry.makeAll()`. That one list feeds the
  app, the CLI and the tests.
- Sources **throw** rather than return zeros. A failed read and an idle system
  must never look the same on a chart; the UI greys the card out instead.
- Formatting lives in `Format`, not in views. The same number appears in a gauge
  readout, a tick label, a chart axis and CLI output, and they have to agree.
- Sources are `final class … MetricSource, @unchecked Sendable`: each holds
  mutable state between reads (previous ticks, a `RateTracker`, a cached
  interface list) and the sampler is the only caller.
- Every layout constant lives in `Theme.Layout`, not in the views. Card size,
  column count and density are one decision, not eight. The three *resizable*
  sizes are the exception: their bounds are in `PanelSize` in `MonitorCore`,
  because a stored size has to be clamped by the value type that holds it.
  `Theme.Layout` forwards to them, so views still read one place.
- Tests are one `@Suite` per area with `@Test` cases. `MonitorCoreTests` use
  fixed inputs; `MonitorSourcesTests` read this machine and assert shape and
  plausible range.

## Making Changes

* **One pull request per piece of work, not per commit.** Related changes ship
  together even when they touch different files and could be described
  separately. Splitting a session's work into several pull requests is the
  wrong default here: they end up *stacked* — each based on the one before —
  and a stacked pull request is not independently reviewable or mergeable, so
  the split buys none of the review value it looks like it buys. What it costs
  is real: a squash-merge and a **release** each, for one change. Keep the
  separable history in the commits, where it is free.
  **This matters most for UI work, which cannot be reviewed piecemeal.** There
  is one window. A change to a card, the axis under it and the title bar above
  it are seen together or not at all, and the only useful question — does this
  read better — can only be asked of the whole screen. Three pull requests
  against one screenshot is three views of a thing nobody can look at
  separately.
  Split only when the parts are genuinely independent of each other and could
  land in either order.
* Make minimal, focused changes; avoid broad refactors unless requested.
* Preserve existing architecture and patterns.
* Don't introduce new dependencies without justification.
* Update tests when behavior changes; update docs when user-visible
  behavior, configuration, or workflows change.

- Verify a UI change by looking at it (`swift run monitor`), not only by
  building. A passing test suite says nothing about whether a needle is legible.
- When adding a metric, decide its `MetricUnit` and `MetricKind` first. Those
  two choices determine the axis, the formatting and whether it needs rate
  differentiation, and getting them wrong produces a chart that is quietly
  wrong rather than obviously broken.

## Guardrails

### Always

- Run `swift build && swift test` and `swiftformat Sources Tests Plugins --lint --cache
  ignore` before considering work done. Both are CI gates.
- Keep `MonitorCore` free of macOS system APIs. It is the part that can be
  tested on any machine in any state, and that is worth protecting.

### Never

- **Never make `monitor`, `MonitorUI` or `monitorctl` depend on
  `MonitorStore`.** v1 writes nothing to disk, and the dependency graph in
  `Package.swift` is what enforces it — the app has no code path that reaches
  the filesystem. This is about SSD endurance: a monitor runs all day, every
  day. Adding that dependency is a deliberate product decision with an
  arithmetic argument behind it (`docs/storage.md`), never a convenience during
  a refactor. Preferences are the exception that proves the rule: layout
  choices go to `UserDefaults` under `wtf.evan.monitor`, which is a write when
  somebody ticks a checkbox, not a write every half second forever.
- **Never save the arrangement on change.** It is mutated on every frame of a
  drag and every frame of a slider. Save when the gesture ends — see
  `commitArrangement`.
- Never report a fabricated value when a source fails. Throw
  `MetricSourceError` and let the UI say "not available". A plausible wrong
  number in a monitoring tool is worse than a gap, because nobody checks it.
- Never auto-scale a `fraction` metric's y-axis. A CPU chart scaled to its own
  2% noise looks like a machine on fire. Fractions are pinned to 0...1.

### Use Extra Caution

- `Sources/MonitorSources/GPUSource.swift` — reads undocumented `IOAccelerator`
  keys that have changed across macOS releases. It looks each one up from a
  candidate list and reports unavailable on a miss. The alternatives (root for
  `powermetrics`, private IOReport) are worse; the file explains why.
- `Sources/MonitorSources/CPUSource.swift` — `host_processor_info` allocates
  into the task's VM and the caller owns it. The `vm_deallocate` in the `defer`
  is not optional; without it the app leaks on every tick.
- `Sources/MonitorSources/SMC.swift` — `SMCParameters` must match the driver's
  struct byte for byte; a field added or reordered silently reads the wrong
  offsets. Only two of the SMC's fifty-odd power keys are named, because only
  those two were checked against an independent measurement (`docs/sensors.md`).
- `Sources/MonitorSources/DiskSource.swift` — the statistics keys are string
  literals because the `kIOBlockStorageDriver…` constants live in a header that
  is not in IOKit's Swift module map. They are not typos.
- `.github/workflows/ci.yml` — the jobs run on a Mac on a desk, so both are
  guarded to skip pull requests from forks. Keep that condition on any job
  added.
- `.github/workflows/release.yml` — `package.yml` is called as a reusable
  workflow rather than listening for `release: published`, because a release
  created with the default `GITHUB_TOKEN` does not fire that event. Splitting
  them into two independent workflows would publish releases with no zip
  attached. It also pushes to the branch it watches, which is a loop unless
  both locks stay on: `[skip ci]` in the bump commit, and the `if:` guard on
  the `tag` job that ignores a commit carrying it. The tag targets the bump
  commit rather than `GITHUB_SHA`, or the zip reports the version before it.

## Troubleshooting

- **Nothing on the panel can be dragged at all**: something hit-testable is
  sitting above the tile. A drop target must not be an `.overlay` with a
  `contentShape` — an overlay is above the content, so it swallows the
  mouse-down and `.draggable` never sees a press. `ReorderDrag` uses one
  `DropDelegate` over the tile and reads `DropInfo.location` to tell the halves
  apart; the width comes from a background `GeometryReader`, which is not
  hit-testable.
- **Dragging works in `monitor.app` but not in `swift run monitor`**: something
  in the drag payload needs an `Info.plist`, and the development build has no
  bundle. This is why the payload is plain text behind a private prefix rather
  than a custom `UTType(exportedAs:)` — that route silently matched no drop
  destination at all when unbundled. Verify drags with `swift run`, not only
  with a packaged build.
- **A rate metric shows nothing on the first tick**: correct by design. Counters
  need two readings. `monitorctl read` takes two ticks for this reason.
- **The window opens behind other apps, or the app is missing from Cmd-Tab**:
  the `AppDelegate` in `Sources/monitor/MonitorApp.swift` sets
  `NSApp.setActivationPolicy(.regular)` at launch, which is what gives an
  unbundled SwiftPM executable a Dock icon, a Cmd-Tab entry and a menu bar with
  Cmd-Q. Do not remove it; without it the process launches as an accessory and
  the only way to stop it is to interrupt the terminal.
- **GPU card is greyed out**: this macOS version does not publish the
  `PerformanceStatistics` keys the source knows about. Add the new spelling to
  the candidate list in `GPUSource`.
- **A merge shipped a patch version when it was labelled `release:minor`**:
  the label lookup came back empty. Check the "Version" step's log — it now
  prints the pull request number, the labels it found and the bump it chose. A
  number of `none` on a squash merge means the subject did not end in `(#N)`;
  empty labels on a real number means the token could not read them, so check
  `pull-requests: read` is still in the workflow's `permissions:`.
- **A pull request reports no CI**: it came from a fork, and the jobs skip fork
  pull requests on purpose. Re-run from a branch in this repository.
- **A pull request reports no CI and did not come from a fork**: its commit
  message or pull request body contains the skip-ci marker, probably while
  *describing* the release workflow. GitHub reads that marker anywhere in a
  commit message and starts no run at all, and a squash merge takes the pull
  request body as the commit message — so a merge like that would also skip
  the release. Write the marker as "skip-ci" in prose and keep the literal
  form inside `release.yml`.
- **CPU shows no cluster series**: correct on a machine with one performance
  level, or when the `hw.perflevel*` core counts do not sum to the core count.
  `CPUSource.readClusters` returns empty rather than guess a wrong split.

## Agent Notes

This file is symlinked to CLAUDE.md and GEMINI.md; keep all instructions
tool-neutral.
