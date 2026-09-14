# monitor-exporter

A headless daemon that serves this Mac's SMC and GPU sensors as Prometheus
metrics on `GET /metrics`, for a Prometheus server to scrape.

```sh
swift run monitor-exporter                        # serve on 127.0.0.1:9650
curl -s localhost:9650/metrics
```

```
--bind-port <port>      TCP port to listen on. Default 9650.
--bind-address <addr>   Address to bind. Default 127.0.0.1; 0.0.0.0 for a
                        remote Prometheus.
```

## What it exports, and what it does not

It reads the sensors **at scrape time**, so the scrape interval is the sampling
rate — there is nothing to configure.

It exports only the macOS gap that node_exporter cannot read: the SMC
(temperature, fans, power) and the GPU. CPU, memory, disk and network are
node_exporter's job on macOS, so running both scrapes each number once rather
than twice under two names.

| Metric | Type | Labels |
|--------|------|--------|
| `macos_smc_temperature_celsius` | gauge | `sensor="cpu\|gpu\|storage\|battery\|enclosure\|ambient"` |
| `macos_smc_fan_rpm` | gauge | `fan="1\|2\|…"` (one-based) |
| `macos_smc_power_watts` | gauge | `rail="input\|soc"` |
| `macos_gpu_utilization_ratio` | gauge | — (0 to 1) |
| `macos_gpu_vram_used_bytes` | gauge | — |
| `monitor_exporter_build_info` | gauge | `version`, `commit`; value always `1` |

A sensor this machine does not have produces **no series**, never a zero — a
fanless Mac has no `macos_smc_fan_rpm`. Temperatures are Celsius only; Grafana
converts. There is no `hostname` label — the scrape target's `instance`
identifies the Mac.

## How it is built

- No new dependency. The exposition format is rendered in-house by the
  `MonitorPrometheus` library (a golden-file test pins it), and the endpoint is
  a single `Network.framework` `NWListener` route.
- It reuses `MonitorSources` — the same readers behind the app and `monitord` —
  and links neither `MonitorLog` nor `MonitorStore`: it writes no files.
- A dead exporter fails the scrape (`up == 0`) rather than serving a stale
  reading, which is why it listens on its own port instead of writing a
  node_exporter textfile.

## Running it for real

[docs/exporter.md](../../docs/exporter.md) has the launchd `LaunchAgent` plist
and a Prometheus `scrape_configs` job.
