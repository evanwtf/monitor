# monitor-exporter

`monitor-exporter` serves this Mac's SMC and GPU sensors as Prometheus metrics
on `GET /metrics`, for a Prometheus server to scrape. It reads the sensors at
scrape time, so the scrape interval *is* the sampling rate — there is no
interval to configure.

## Scope: the macOS gap, not everything

node_exporter's darwin collectors already read CPU, memory, disk and network.
What node_exporter does **not** read on macOS is the SMC (temperature, fans,
power) and the GPU. `monitor-exporter` exports exactly that gap, so running both
scrapes each number once rather than twice under two names.

A sensor this machine does not have produces **no series**, never a zero — a
fanless MacBook Air has no `macos_smc_fan_rpm`, and a Mac that does not publish
an ambient sensor has no `sensor="ambient"` line. An idle sensor and a missing
one must not read alike.

## Metrics

| Metric | Type | Labels |
|--------|------|--------|
| `macos_smc_temperature_celsius` | gauge | `sensor="cpu\|gpu\|storage\|battery\|enclosure\|ambient"` |
| `macos_smc_fan_rpm` | gauge | `fan="1\|2\|…"` (one-based) |
| `macos_smc_power_watts` | gauge | `rail="input\|soc"` |
| `macos_gpu_utilization_ratio` | gauge | — (0 to 1) |
| `macos_gpu_vram_used_bytes` | gauge | — |
| `monitor_exporter_build_info` | gauge | `version`, `commit`; value always `1` |

Temperatures are Celsius only — Grafana converts to °F. There is no `hostname`
label; the scrape target's `instance` identifies the Mac.

## Run it as a launchd LaunchAgent

Save as `~/Library/LaunchAgents/wtf.evan.monitor-exporter.plist`, then
`launchctl load` it. Adjust the binary path to where you unzipped the release.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>wtf.evan.monitor-exporter</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/monitor-exporter</string>
        <string>--bind-port</string>
        <string>9650</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/monitor-exporter.log</string>
    <key>StandardOutPath</key>
    <string>/tmp/monitor-exporter.log</string>
</dict>
</plist>
```

```sh
launchctl load ~/Library/LaunchAgents/wtf.evan.monitor-exporter.plist
curl -s localhost:9650/metrics   # confirm it answers
```

`--bind-address` defaults to `127.0.0.1`. Pass `--bind-address 0.0.0.0` (add it
to `ProgramArguments`) only when a Prometheus server on another host must reach
it, and firewall the port to that host — the endpoint has no authentication,
which is fine for a read-only metrics port on a trusted network.

## Prometheus scrape config

The default port `9650` is verified free in the Prometheus
default-port-allocations registry — clear of node_exporter (9100) and the dense
exporter band around it.

```yaml
scrape_configs:
  - job_name: macos-sensors
    static_configs:
      - targets: ["<this-mac-host>:9650"]
```

A dead exporter fails the scrape, so Prometheus surfaces it as `up == 0` — no
separate staleness alert to maintain, which is the reason this listens on its
own port rather than writing a node_exporter textfile.
