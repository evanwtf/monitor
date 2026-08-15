# Sensors

What a Mac will tell you about its own heat, fans and power, what each route
costs, and which of them need privileges.

Surveyed on a MacBook Air (13-inch, M5) — `Mac17,3`, macOS 26.6 — running as an
ordinary user with no helper tool and no `sudo`. Counts are from that machine;
the *routes* are the same on any Mac.

## The short answer

**Temperature, power and fan speed are all readable unprivileged.** Nothing in
the sensor section needs root, an installer, or a privileged helper.

Root is needed for exactly two things, and the app does neither:

| Wants root | Why we do not need it |
|-----------|-----------------------|
| `powermetrics` | It reads the same SMC and IOReport data the app reads directly |
| *Writing* SMC keys — setting a fan speed | This is a monitor. `SMC` has no write path |

## The four routes

### 1. SMC — what the app uses

`IOServiceOpen` on `AppleSMC`, then one struct-method selector. Undocumented,
unprivileged, and present on every Mac including Intel.

- **2294 keys** on this machine: 148 temperatures (`T…`), 55 power (`P…`), 44
  current (`I…`), 40 voltage (`V…`), 254 battery (`B…`), **0 fans** — this model
  is fanless, and the fan keys are simply absent rather than reading zero.
- **Cost**: ~350 µs per key for a cold read (one call for the key's type and
  size, one for the bytes), ~175 µs once the type is cached. Reading all 148
  temperatures every tick would cost 26 ms — which is why `SMCSource` caps each
  metric at six sensors and reads about twenty keys in total, ~4 ms per tick.
- **Enumerating** every key name takes 314 ms, far too long to spend at launch.
  The key table is sorted, so `SMC.keys(withPrefix:)` binary-searches to the
  start of the `T` range and walks it: ~30 ms, once, at startup.
- **Types** are a fixed-point zoo: `flt` (little-endian float, Apple silicon),
  `sp78` and `fp88` (Intel temperatures), `fpe2` (Intel fan rpm), `ui8`…`ui32`.
  Decoding one as another produces a number that looks like a temperature.

### 2. IORegistry — `AppleSmartBattery`

Public IOKit, no privileges. Charge, cycle count, design capacity, pack voltage
and amperage, adapter details, pack temperature, and a `PowerTelemetryData`
dictionary with `SystemPowerIn` in mW.

Not used for live power: the telemetry values are accumulator-backed and were
observed unchanged (5332 mW) across a 30× swing in real load. It is the right
source for *battery state*, which is a candidate for a later card, not for
watts now.

### 3. IOReport — surveyed, deliberately unused

`/usr/lib/libIOReport.dylib`, resolved by `dlsym`. **8653 channels** are
visible, subscribable and delta-able as an ordinary user — no entitlement was
needed for any of it:

- `Energy Model` — 167 channels of energy in mJ: per-core (`ECPU0…5`,
  `PCPU0…3`), per-cluster, `GPU`, `ANE`, `DRAM`, `DISP`, `ISP`, `PCIe`. This is
  where a true per-component watt figure lives.
- `CPU Stats / CPU Complex Performance States` — P-state residencies, which is
  how you get an average clock frequency.
- `GPU Stats`, `AMC Stats / Perf Counters` — GPU residency and memory bandwidth.

It is not used for the same reason `GPUSource` gives: it is a private framework,
and depending on it would rule out ever shipping through the App Store. Its
value here was as an *oracle* — an independent measurement to check the SMC key
names against (below).

### 4. Public API — free, already available

`ProcessInfo.thermalState` (nominal / fair / serious / critical) and
`isLowPowerModeEnabled`. Neither is a sensor reading, but both explain one: a
machine at `serious` is being throttled, which is the reason a chart flattened.

## What the app reports

`SMCSource` declares a metric only if this machine publishes sensors for it, so
a fanless laptop shows no Fans card at all and an Intel Mac's `TC0P` feeds the
same CPU metric as Apple silicon's `Tp01`.

| Metric | Keys | Notes |
|--------|------|-------|
| `sensor.temperature.cpu` | `Tp…`, `Te…`; Intel `TC0P`/`TC0D`/`TCXC` | hottest die sensor |
| `sensor.temperature.gpu` | `Tg…`; Intel `TG0P`/`TG0D` | hottest die sensor |
| `sensor.temperature.storage` | `TH0…` | internal SSD, including the NAND sensor |
| `sensor.temperature.battery` | `TB…T` | one metric per pack, hottest cell |
| `sensor.temperature.enclosure` | `Ts…P` | the case, i.e. what your hands feel |
| `sensor.temperature.ambient` | `TA…P` | not published by every model |
| `sensor.power.input` | `PDTR` | DC in |
| `sensor.power.soc` | `PHPS` | package: CPU + GPU + memory |
| `sensor.fan.N.speed` | `FNAc`, scaled by `FNMx` | fanless models publish none |

Temperatures take the **hottest** of their sensors rather than the mean: the
hot spot is what throttles the machine, and averaging fourteen die sensors
hides the one that is about to.

### How many keys is "their sensors"?

Wildly model-dependent, and not predictable from the model name. A 16-inch
MacBook Pro of 2026 publishes 568 readable keys, of which:

| Family | Keys on that machine |
|---|---|
| GPU `Tg…` | 84 |
| CPU `Tp…`/`Te…` | 23 |
| SSD `TH0…` | 3 |
| Battery `TB…T` | 3 |
| Enclosure `Ts…P` | 2 |
| Ambient `TA…P` | 0 |

Another Mac will not match that table, which is the argument for discovering
everything at launch rather than shipping a list per model. It is also why
`hottest` must mean *all* of them: this source once read the first six of each
family, so a machine with 23 die sensors reported the hottest of an arbitrary
six and called it the hottest. On this machine that understated the CPU by
three degrees.

Reading them all costs about 0.15 ms per key, so a tick of this source runs
around 15 ms here against 4 ms when it sampled six. That is the price of the
metric meaning what it says.

Charts are pinned to 0–110 °C rather than auto-scaled, for the same reason CPU
load is pinned to 0–100%: a chart scaled to 2 °C of drift makes a cool machine
look like a fire.

## Why those two power keys, and not the other fifty-three

A plausible wrong watt figure is worse than no watt figure, so a `P…` key is
only named if its meaning was checked against something independent. Two were:

- **`PDTR` = DC input power.** It equals `VD0R × ID0R`, the input rail's own
  voltage and current keys, to three decimal places at both idle (19.947 V ×
  0.291 A = 5.81 W) and load (19.679 × 1.790 = 35.23 W).
- **`PHPS` = SoC package power.** Under an eight-thread load it read 18.1 W
  while IOReport's Energy Model independently reported 17.34 W of CPU energy
  plus 0.17 W DRAM, 0.14 W DCS, 0.09 W display and 0.03 W GPU — 17.8 W, within
  2%. At idle both fall below 1 W together.

One trap worth recording: **`PSTR` is `PDTR` one sample late.** Read them in the
same tick and `PSTR(t)` is exactly, bit for bit, `PDTR(t−1)`. Charting both
would draw the same series twice and make a lag look like a second measurement.

## What is deliberately not read

- The other ~2270 SMC keys. Most are configuration, limits, or rails whose
  meaning cannot be checked, and `TPDD`, `Tz11` and friends read a flat 0 —
  the key exists, the hardware behind it does not. A zero temperature is
  therefore treated as a missing sensor, not a cold one.
- Per-component watts (CPU vs GPU vs ANE) — that needs IOReport.
- CPU clock frequency — same.
- Battery charge, health and time remaining — `AppleSmartBattery` has all of it,
  and it belongs on a battery card rather than in a sensor sweep.
