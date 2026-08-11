# Metrics

Every metric has a stable `MetricID`, a `MetricUnit` that decides how it is
drawn and formatted, and a `MetricKind` that decides whether it needs rate
differentiation.

`MetricID` raw values are the on-disk keys for stored history. **Renaming one
orphans its data.** Add a new id rather than renaming an old one.

## CPU — `CPUSource`

`host_processor_info(PROCESSOR_CPU_LOAD_INFO)`. The kernel reports cumulative
ticks per core in four states (user, system, idle, nice), so load is the
difference between two readings. The first read produces nothing but a baseline.

| id | Meaning |
|----|---------|
| `cpu.total` | busy fraction across all cores |
| `cpu.user` | user + nice |
| `cpu.system` | system |
| `cpu.perflevel.N` | mean busy fraction across performance level N's cores |

All are `fraction`, pinned to 0–1 on a chart.

Load is reported **per cluster**, one series per `hw.perflevel`, and never
averaged across them: on Apple silicon a performance core and an efficiency core
have different ceilings, so their mean describes nothing physical. Within a
cluster the mean is exactly right, because those cores are interchangeable to
the scheduler.

A line per core says less than a line per cluster. At ten cores the chart is
unreadable spaghetti and its legend does not fit, and the question a dashboard
answers is "is the fast cluster working", not "which of these four".

Two details about the mapping:

- The id is keyed by performance level, not by the cluster's name.
  `hw.perflevel0` is always the fastest cluster on any machine that has them, so
  the id means the same thing everywhere. The name does not: an M4 calls level 0
  "Super" where earlier silicon calls it "Performance".
- `host_processor_info` numbers cores in **reverse** performance-level order —
  the *slowest* cluster comes first. Verified on an M4 (10 cores, 4 at level 0
  "Super", 6 at level 1 "Efficiency") by pinning four `userInteractive` threads,
  which the scheduler puts on the fast cluster: cores 6–9 hit 99% while 0–5
  stayed idle.

A machine with fewer than two performance levels — any Intel Mac — gets no
cluster series at all, since one uniform "cluster" would just duplicate
`cpu.total`. The source also reports none if the level sizes do not add up to
the core count: a wrong split would attribute real load to the wrong kind of
core, which is worse than no split.

## Memory — `MemorySource`

`host_statistics64(HOST_VM_INFO64)` plus `sysctl(VM_SWAPUSAGE)`.

| id | Meaning |
|----|---------|
| `memory.used` | app + wired + compressed |
| `memory.app` | anonymous pages: active + inactive − purgeable − file-backed |
| `memory.wired` | pages the kernel cannot page out |
| `memory.compressed` | pages held by the compressor |
| `memory.cached` | file-backed + purgeable — reclaimable on demand |
| `memory.free` | genuinely free pages |
| `memory.swap.used` | swap in use |
| `memory.pagein.rate`, `memory.pageout.rate` | paging operations per second |

"Used" follows Activity Monitor's definition rather than the raw page counts.
Inactive and purgeable pages are **not** counted as used, because macOS reclaims
them on demand — counting them makes a perfectly healthy machine look full,
which is how "my Mac is out of RAM" panics start.

Page size comes from `sysconf(_SC_PAGESIZE)`, not the `vm_kernel_page_size`
global, which Swift 6 rejects as shared mutable state.

## Disk — `DiskSource`

IOKit registry, `IOBlockStorageDriver`, the `Statistics` dictionary. Cumulative
since boot, so everything here is differentiated into a rate. Summed across all
block devices; per-volume breakout is on the roadmap.

| id | Meaning |
|----|---------|
| `disk.bytes.read`, `disk.bytes.written` | throughput |
| `disk.ops.read`, `disk.ops.write` | IOPS |
| `disk.latency.read`, `disk.latency.write` | mean latency this interval |

Latency is the number that actually explains a stalled machine: throughput can
read as idle while every single read takes 40 ms. It is computed as the delta in
total time divided by the delta in operation count. Dividing the cumulative
totals instead would give the average since boot, which never moves and is
therefore useless.

**An interval with no operations reports a latency of zero, not nothing.** With
no operations both deltas are zero, so there is no quotient to take, and zero is
a choice rather than a computation — the right one, because no time was spent
waiting on the disk. Reporting nothing instead made latency the only one of this
source's six metrics that could go absent on an idle tick, and the UI reads an
absent metric as "not available on this machine": a claim about the hardware. The
Disk Latency card flapped between its chart and that notice twice a second on an
idle machine as a result (#5).

The consequence worth knowing is that "operations completed instantly" and
"nothing happened" both draw as zero. The Disk Ops card beside it tells the two
apart.

Only the *first* tick reports no latency at all, because the counters have no
previous reading and there is genuinely no rate yet — which is a different thing
from an idle interval.

The dictionary keys are string literals because the `kIOBlockStorageDriver…`
constants live in a header that is not in IOKit's Swift module map.

## Network — `NetworkSource`

`getifaddrs`, `AF_LINK` entries only, restricted to physical interfaces.

| id | Meaning |
|----|---------|
| `net.bits.in`, `net.bits.out` | throughput, in **bits** per second |
| `net.packets.in`, `net.packets.out` | packet rate |

Only `AF_LINK` entries carry counters; an interface also has an `AF_INET` entry
and counting both would double every byte.

**Only real NICs are counted — Wi-Fi and wired.** A Mac carries a crowd of
interfaces that are not the network, and summing everything `getifaddrs` returns
reports more traffic than crossed the wire:

| interface | what it is |
|-----------|------------|
| `lo0` | the machine talking to itself; swamps the chart during a build |
| `utun0…8` | VPN and per-app tunnels. Traffic through one is counted **twice** if you sum both the tunnel and the `en0` it leaves by |
| `awdl0` | AirDrop / AirPlay |
| `llw0`, `anpi0`, `ap1` | Apple's link-local and internal interfaces |
| `bridge0` | Thunderbolt Bridge — real hardware underneath, virtual interface on top |
| `gif0`, `stf0` | IPv6 transition pseudo-devices |

The list of real interfaces comes from `SCNetworkInterfaceCopyAll`, filtered to
the `Ethernet` and `IEEE80211` types. That is an allow-list of interface *types*,
deliberately, rather than a deny-list of name prefixes: a deny-list has to be
extended every time Apple ships another `anpi`-style internal interface, and the
failure mode of missing one is silently over-reporting traffic — the kind of
wrong number nobody checks.

`SCNetworkInterfaceCopyAll` costs about 0.8 ms, which is far too much at two
reads a second, so the result is cached and re-resolved every 10 seconds. A
dongle plugged in mid-session appears within that window.

The byte counters are multiplied by 8 and reported as bits. Every number anyone
quotes about a network is in bits — a 1 Gbit port, a 300 Mbit service, an
866 Mbit Wi-Fi link — so reporting bytes makes the reader divide by eight before
they can tell whether a link is busy. The conversion happens in the source, not
in the gauge, so the dial, the chart axis and `monitorctl` cannot disagree
about it.

## GPU — `GPUSource`

IOKit registry, `IOAccelerator`, `PerformanceStatistics`.

| id | Meaning |
|----|---------|
| `gpu.utilization` | busiest accelerator's device utilization |
| `gpu.vram.used` | VRAM in use, summed |

Apple publishes **no supported API** for GPU utilization. The keys here are
undocumented and have changed across macOS releases, so each is looked up from a
list of known spellings and a miss reports the source as unavailable rather than
guessing. Utilization takes the maximum across accelerators, not the mean: with
two GPUs, one pinned and one idle is not "half loaded".

## Units

| Unit | Axis behaviour |
|------|----------------|
| `fraction` | pinned to 0–1, never auto-scaled |
| `bytes` | decimal units (kB = 1000), matching Apple, scaled to the data |
| `bytesPerSecond` | decimal units, **always MB/s** — never rescaled |
| `bitsPerSecond` | decimal units, **always Mbit/s** — never rescaled |
| `operationsPerSecond`, `count`, `hertz` | scaled to the data |
| `seconds` | µs / ms / s by magnitude |
| `celsius`, `watts` | declared, not yet produced by any source |

Throughput is pinned to mega-units at every magnitude, including `0.02 MB/s`
and `5000 MB/s`. Auto-scaling suits an axis and not an instrument: the unit
under a needle you are watching must not change while you are reading it, and a
readout of `900` is useless until you have also read the word beneath it. The
A chart axis and the CLI carry three significant figures, which keeps a value's
width near-constant as it moves. The gauge readout goes further and uses a fixed
`xxxx.yy` field so the decimal point never moves at all — see `docs/ui.md`.
