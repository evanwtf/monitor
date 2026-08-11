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
| `cpu.core.N` | busy fraction of one core |

All are `fraction`, pinned to 0–1 on a chart.

Cores are reported separately and never averaged into a single "CPU speed". On
Apple silicon a performance core and an efficiency core have different ceilings,
so their mean describes nothing physical.

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

The dictionary keys are string literals because the `kIOBlockStorageDriver…`
constants live in a header that is not in IOKit's Swift module map.

## Network — `NetworkSource`

`getifaddrs`, `AF_LINK` entries only, loopback excluded.

| id | Meaning |
|----|---------|
| `net.bytes.in`, `net.bytes.out` | throughput |
| `net.packets.in`, `net.packets.out` | packet rate |

Only `AF_LINK` entries carry counters; an interface also has an `AF_INET` entry
and counting both would double every byte. Loopback is excluded because it is
the machine talking to itself and it swamps the chart during a build.

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
| `bytes`, `bytesPerSecond` | decimal units (kB = 1000), matching Apple |
| `operationsPerSecond`, `count`, `hertz` | scaled to the data |
| `seconds` | µs / ms / s by magnitude |
| `celsius`, `watts` | declared, not yet produced by any source |
