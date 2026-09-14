# monitor-exporter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `monitor-exporter` binary that serves the macOS SMC and GPU sensors as Prometheus metrics on `GET /metrics`, for a Prometheus server to scrape.

**Architecture:** A pure `MonitorPrometheus` library (on `MonitorCore` only) renders the text exposition format and maps sensor `MetricID`s to metric names. A thin `monitor-exporter` executable reads the gap sources (`SourceRegistry.make(ids: ["sensors", "gpu"])`) at scrape time and serves the rendered body over an `NWListener`. No new dependency.

**Tech Stack:** Swift 6, SwiftPM, macOS 14+, `Network.framework`, swift-testing (`@Suite`/`@Test`/`#expect`), `swift-argument-parser` (already present).

**Spec:** evanwtf/monitor#58 (design capture, with the real `monitord` CSV columns as the metric source of truth).

## Global Constraints

- Swift 6 (`swift-tools-version: 6.0`), macOS 14+. Tests use swift-testing, never XCTest.
- **No new package dependency.** Exposition is rendered in-house; HTTP is `NWListener`.
- **Gap, never zero.** A sensor this machine lacks produces *no* series — never a `0`. An empty metric family is omitted entirely.
- **Metric names are a public contract.** `macos_smc_temperature_celsius`, `macos_smc_fan_rpm`, `macos_smc_power_watts`, `macos_gpu_utilization_ratio`, `macos_gpu_vram_used_bytes`, plus `monitor_exporter_build_info`. One canonical unit (`_celsius`, drop °F). No `hostname` label — `instance` covers it.
- **Default scope is the macOS gap only** (SMC + GPU). `--all` (CPU/memory/disk/network) is deferred, out of this plan.
- Default `--bind-port 9650` (verified free in the Prometheus default-port-allocations registry), default `--bind-address 127.0.0.1`.
- `MetricID` raw values are on-disk keys; this plan only *reads* them, never renames.
- Lint gate: `swiftformat Sources Tests Plugins --lint --cache ignore` must pass.

---

## File Structure

```
Sources/MonitorPrometheus/
  Exposition.swift        types (PrometheusLabel/Sample/Family) + renderExposition + families builder
  PrometheusMapping.swift MetricID -> MappedMetric (name, help, labels); nil for non-gap
Sources/MonitorExporter/
  MonitorExporter.swift   MonitorExporterCommand (ParsableCommand) + @main
  MetricsHandler.swift    reads sources at scrape time -> exposition body; build_info; lock
  MetricsServer.swift     NWListener; route(request:body:) pure; 200 /metrics else 404
Tests/MonitorPrometheusTests/
  ExpositionTests.swift   golden-file format test
  MappingTests.swift      each sensor id -> family/label; non-gap id -> nil
Tests/MonitorExporterTests/
  MetricsHandlerTests.swift   fake source: maps known, drops unmapped, always build_info
  MetricsServerTests.swift    route() unit test + a real bound-port scrape
Tests/CommandLineTests/
  MonitorExporterArgumentTests.swift   flag parsing / defaults / unknown-flag rejection
Package.swift             + MonitorPrometheus lib, MonitorExporter exe + product, test targets
.github/workflows/ci.yml  + exporter --help/--version smoke + endpoint smoke
Scripts/make-app.sh       stage monitor-exporter beside monitord in the zip
README.md, AGENTS.md      document the exporter
docs/exporter.md          launchd LaunchAgent example
```

---

### Task 1: MonitorPrometheus — exposition renderer

**Files:**
- Modify: `Package.swift` (add `MonitorPrometheus` library product + target; add `MonitorPrometheusTests` target)
- Create: `Sources/MonitorPrometheus/Exposition.swift`
- Test: `Tests/MonitorPrometheusTests/ExpositionTests.swift`

**Interfaces produced:**
- `struct PrometheusLabel { let name, value: String }`
- `struct PrometheusSample { let labels: [PrometheusLabel]; let value: Double }`
- `struct PrometheusFamily { let name, help: String; let samples: [PrometheusSample] }`
- `func renderExposition(_ families: [PrometheusFamily]) -> String`
- internal `func renderLabels(_:) -> String` (reused by the families builder in Task 2)

- [ ] **Step 1 — Package.swift.** Add under products: `.library(name: "MonitorPrometheus", targets: ["MonitorPrometheus"]),`. Add under targets:
```swift
.target(name: "MonitorPrometheus", dependencies: ["MonitorCore"]),
.testTarget(
    name: "MonitorPrometheusTests",
    dependencies: ["MonitorPrometheus", "MonitorCore", "MonitorSources"]),
```

- [ ] **Step 2 — write the failing test** `Tests/MonitorPrometheusTests/ExpositionTests.swift`:
```swift
@testable import MonitorPrometheus
import Testing

@Suite("Exposition format")
struct ExpositionTests {
    @Test("a family renders HELP, TYPE and label-sorted value lines, with a trailing newline")
    func rendersFamily() {
        let family = PrometheusFamily(
            name: "macos_smc_temperature_celsius",
            help: "SMC temperature sensor reading, in degrees Celsius.",
            samples: [
                PrometheusSample(labels: [PrometheusLabel(name: "sensor", value: "gpu")], value: 76.78),
                PrometheusSample(labels: [PrometheusLabel(name: "sensor", value: "cpu")], value: 72.33),
            ]
        )
        let expected = [
            "# HELP macos_smc_temperature_celsius SMC temperature sensor reading, in degrees Celsius.",
            "# TYPE macos_smc_temperature_celsius gauge",
            #"macos_smc_temperature_celsius{sensor="cpu"} 72.33"#,
            #"macos_smc_temperature_celsius{sensor="gpu"} 76.78"#,
            "",
        ].joined(separator: "\n")
        #expect(renderExposition([family]) == expected)
    }

    @Test("an integral value drops the decimal point")
    func integralValue() {
        let f = PrometheusFamily(
            name: "macos_smc_fan_rpm", help: "h",
            samples: [PrometheusSample(labels: [PrometheusLabel(name: "fan", value: "1")], value: 3187)])
        #expect(renderExposition([f]).contains("macos_smc_fan_rpm{fan=\"1\"} 3187\n"))
    }

    @Test("a family with no samples is omitted entirely")
    func emptyFamilyOmitted() {
        #expect(renderExposition([PrometheusFamily(name: "x", help: "h", samples: [])]).isEmpty)
    }

    @Test("a label value with a quote or backslash is escaped")
    func escaping() {
        let f = PrometheusFamily(
            name: "x", help: "h",
            samples: [PrometheusSample(labels: [PrometheusLabel(name: "k", value: #"a"b\c"#)], value: 1)])
        #expect(renderExposition([f]).contains(#"x{k="a\"b\\c"} 1"#))
    }

    @Test("labels are unnamed metrics render with no braces")
    func noLabels() {
        let f = PrometheusFamily(name: "macos_gpu_utilization_ratio", help: "h",
                                 samples: [PrometheusSample(labels: [], value: 0.99)])
        #expect(renderExposition([f]).contains("macos_gpu_utilization_ratio 0.99\n"))
    }
}
```

- [ ] **Step 3 — run, expect FAIL** (`swift test --filter Exposition`): compile error, `renderExposition` undefined.

- [ ] **Step 4 — implement** `Sources/MonitorPrometheus/Exposition.swift`:
```swift
import Foundation

/// One label on a Prometheus series, e.g. `sensor="cpu"`.
public struct PrometheusLabel: Hashable, Sendable {
    public let name: String
    public let value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One value line: a label set and its reading.
public struct PrometheusSample: Hashable, Sendable {
    public let labels: [PrometheusLabel]
    public let value: Double
    public init(labels: [PrometheusLabel], value: Double) {
        self.labels = labels
        self.value = value
    }
}

/// A metric family: one name, one HELP, one TYPE (always gauge here), and every
/// series under it. An empty family renders nothing — the gap-not-zero rule at
/// the family level.
public struct PrometheusFamily: Hashable, Sendable {
    public let name: String
    public let help: String
    public let samples: [PrometheusSample]
    public init(name: String, help: String, samples: [PrometheusSample]) {
        self.name = name
        self.help = help
        self.samples = samples
    }
}

/// Render families to the Prometheus text exposition format (version 0.0.4).
///
/// Everything here is a gauge; the default sensor set is instantaneous. One
/// `# HELP` and one `# TYPE` per family, then one line per series, labels
/// sorted so the output is byte-stable and a golden test can pin it.
public func renderExposition(_ families: [PrometheusFamily]) -> String {
    var out = ""
    for family in families where !family.samples.isEmpty {
        out += "# HELP \(family.name) \(family.help)\n"
        out += "# TYPE \(family.name) gauge\n"
        for sample in family.samples {
            out += family.name + renderLabels(sample.labels) + " \(formatValue(sample.value))\n"
        }
    }
    return out
}

/// `{a="1",b="2"}`, sorted by label name; empty for no labels.
func renderLabels(_ labels: [PrometheusLabel]) -> String {
    guard !labels.isEmpty else { return "" }
    let inner = labels
        .sorted { $0.name < $1.name }
        .map { "\($0.name)=\"\(escape($0.value))\"" }
        .joined(separator: ",")
    return "{\(inner)}"
}

/// Backslash, double-quote and newline are the three the format reserves.
func escape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}

/// An integral reading prints without a decimal point (`3187`, not `3187.0`);
/// everything else keeps Swift's shortest round-trippable form (`72.33`).
func formatValue(_ value: Double) -> String {
    if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
        return String(Int64(value))
    }
    return String(value)
}
```

- [ ] **Step 5 — run, expect PASS** (`swift test --filter Exposition`).

- [ ] **Step 6 — commit:** `feat: exposition-format renderer for the Prometheus exporter (#58)`

---

### Task 2: MonitorPrometheus — MetricID → Prometheus metric mapping

**Files:**
- Create: `Sources/MonitorPrometheus/PrometheusMapping.swift`
- Test: `Tests/MonitorPrometheusTests/MappingTests.swift`

**Interfaces:**
- Consumes: `PrometheusLabel`, `PrometheusFamily`, `renderLabels` (Task 1); `MonitorCore.MetricID`.
- Produces: `struct MappedMetric { let familyName, help: String; let labels: [PrometheusLabel] }`; `enum PrometheusMapping { static func map(_ id: MetricID) -> MappedMetric? }`; `enum PrometheusFamilyBuilder { static func families(from entries: [(MappedMetric, Double)]) -> [PrometheusFamily] }`.

- [ ] **Step 1 — write the failing test** `Tests/MonitorPrometheusTests/MappingTests.swift` (uses the real `SMCSource`/`GPUSource` constants so a renamed `MetricID` breaks the mapping test, not production):
```swift
import MonitorCore
@testable import MonitorPrometheus
import MonitorSources
import Testing

@Suite("Prometheus mapping")
struct MappingTests {
    @Test("each SMC temperature maps to the temperature family with a sensor label")
    func temperatures() {
        #expect(PrometheusMapping.map(SMCSource.cpuTemperature)
            == MappedMetric(familyName: "macos_smc_temperature_celsius",
                            help: PrometheusMapping.temperatureHelp,
                            labels: [PrometheusLabel(name: "sensor", value: "cpu")]))
        #expect(PrometheusMapping.map(SMCSource.enclosureTemperature)?.labels
            == [PrometheusLabel(name: "sensor", value: "enclosure")])
    }

    @Test("power rails carry a rail label")
    func power() {
        #expect(PrometheusMapping.map(SMCSource.inputPower)?.labels == [PrometheusLabel(name: "rail", value: "input")])
        #expect(PrometheusMapping.map(SMCSource.socPower)?.labels == [PrometheusLabel(name: "rail", value: "soc")])
        #expect(PrometheusMapping.map(SMCSource.socPower)?.familyName == "macos_smc_power_watts")
    }

    @Test("a fan id carries its one-based index as a fan label")
    func fans() {
        #expect(PrometheusMapping.map(SMCSource.fanSpeed(2))
            == MappedMetric(familyName: "macos_smc_fan_rpm", help: PrometheusMapping.fanHelp,
                            labels: [PrometheusLabel(name: "fan", value: "2")]))
    }

    @Test("gpu metrics map to unlabelled families")
    func gpu() {
        #expect(PrometheusMapping.map(GPUSource.utilization)?.familyName == "macos_gpu_utilization_ratio")
        #expect(PrometheusMapping.map(GPUSource.vramUsed)?.familyName == "macos_gpu_vram_used_bytes")
        #expect(PrometheusMapping.map(GPUSource.utilization)?.labels == [])
    }

    @Test("a non-gap metric does not map")
    func nonGap() {
        #expect(PrometheusMapping.map(MetricID("cpu.total")) == nil)
        #expect(PrometheusMapping.map(MetricID("memory.used")) == nil)
        #expect(PrometheusMapping.map(MetricID("net.bits.in")) == nil)
    }

    @Test("families groups entries by name and sorts within a family by label")
    func builder() {
        let entries: [(MappedMetric, Double)] = [
            (PrometheusMapping.map(SMCSource.fanSpeed(2))!, 3400),
            (PrometheusMapping.map(SMCSource.fanSpeed(1))!, 3187),
        ]
        let families = PrometheusFamilyBuilder.families(from: entries)
        #expect(families.count == 1)
        #expect(families[0].name == "macos_smc_fan_rpm")
        #expect(families[0].samples.map(\.value) == [3187, 3400]) // fan="1" sorts before fan="2"
    }
}
```

- [ ] **Step 2 — run, expect FAIL** (`swift test --filter "Prometheus mapping"`).

- [ ] **Step 3 — implement** `Sources/MonitorPrometheus/PrometheusMapping.swift`:
```swift
import MonitorCore

/// A sensor `MetricID` mapped to its Prometheus family name, help text and labels.
public struct MappedMetric: Hashable, Sendable {
    public let familyName: String
    public let help: String
    public let labels: [PrometheusLabel]
    public init(familyName: String, help: String, labels: [PrometheusLabel]) {
        self.familyName = familyName
        self.help = help
        self.labels = labels
    }
}

/// Maps monitord's sensor `MetricID`s to Prometheus metrics — the macOS gap
/// node_exporter does not read. Anything else (CPU, memory, disk, network)
/// returns nil and is dropped, which is how the default scope stays gap-only.
public enum PrometheusMapping {
    public static let temperatureHelp = "SMC temperature sensor reading, in degrees Celsius."
    public static let fanHelp = "SMC fan tachometer reading, in RPM."
    public static let powerHelp = "SMC power rail draw, in watts."
    public static let gpuUtilizationHelp = "GPU utilization, 0 to 1."
    public static let gpuVramHelp = "GPU video memory in use, in bytes."

    public static func map(_ id: MetricID) -> MappedMetric? {
        switch id.rawValue {
        case "sensor.temperature.cpu": return temperature("cpu")
        case "sensor.temperature.gpu": return temperature("gpu")
        case "sensor.temperature.storage": return temperature("storage")
        case "sensor.temperature.battery": return temperature("battery")
        case "sensor.temperature.enclosure": return temperature("enclosure")
        case "sensor.temperature.ambient": return temperature("ambient")
        case "sensor.power.input": return power("input")
        case "sensor.power.soc": return power("soc")
        case "gpu.utilization":
            return MappedMetric(familyName: "macos_gpu_utilization_ratio", help: gpuUtilizationHelp, labels: [])
        case "gpu.vram.used":
            return MappedMetric(familyName: "macos_gpu_vram_used_bytes", help: gpuVramHelp, labels: [])
        default:
            guard let index = fanIndex(id.rawValue) else { return nil }
            return MappedMetric(
                familyName: "macos_smc_fan_rpm", help: fanHelp,
                labels: [PrometheusLabel(name: "fan", value: String(index))])
        }
    }

    /// `sensor.fan.<n>.speed` -> n. Nil for anything else.
    static func fanIndex(_ raw: String) -> Int? {
        let parts = raw.split(separator: ".")
        guard parts.count == 4, parts[0] == "sensor", parts[1] == "fan", parts[3] == "speed",
              let index = Int(parts[2]) else { return nil }
        return index
    }

    private static func temperature(_ sensor: String) -> MappedMetric {
        MappedMetric(familyName: "macos_smc_temperature_celsius", help: temperatureHelp,
                     labels: [PrometheusLabel(name: "sensor", value: sensor)])
    }

    private static func power(_ rail: String) -> MappedMetric {
        MappedMetric(familyName: "macos_smc_power_watts", help: powerHelp,
                     labels: [PrometheusLabel(name: "rail", value: rail)])
    }
}

/// Groups mapped readings into families for rendering. Family names and, within
/// a family, series are sorted so output is byte-stable.
public enum PrometheusFamilyBuilder {
    public static func families(from entries: [(MappedMetric, Double)]) -> [PrometheusFamily] {
        var byName: [String: (help: String, samples: [PrometheusSample])] = [:]
        for (metric, value) in entries {
            byName[metric.familyName, default: (metric.help, [])].samples
                .append(PrometheusSample(labels: metric.labels, value: value))
        }
        return byName.sorted { $0.key < $1.key }.map { name, body in
            PrometheusFamily(
                name: name, help: body.help,
                samples: body.samples.sorted { renderLabels($0.labels) < renderLabels($1.labels) })
        }
    }
}
```

- [ ] **Step 4 — run, expect PASS** (`swift test --filter "Prometheus mapping"`).
- [ ] **Step 5 — commit:** `feat: map sensor MetricIDs to Prometheus metrics (#58)`

---

### Task 3: monitor-exporter executable skeleton + argument parsing

**Files:**
- Modify: `Package.swift` (add executable product `monitor-exporter` + target `MonitorExporter`; add `MonitorExporter` to the `CommandLineTests` deps)
- Create: `Sources/MonitorExporter/MonitorExporter.swift`
- Test: `Tests/CommandLineTests/MonitorExporterArgumentTests.swift`

**Interfaces produced:** `struct MonitorExporterCommand: ParsableCommand` with `var bindPort: UInt16 = 9650`, `var bindAddress: String = "127.0.0.1"`, `static let gapSourceIDs = ["sensors", "gpu"]`; `enum MonitorExporter { static func arguments(rewriting:) -> [String] }`.

> `run()` in this task starts nothing yet (it builds the sources and logs); Task 5 wires the server in. The target must compile and its front door must parse, which is all this task claims.

- [ ] **Step 1 — Package.swift.** Products: `.executable(name: "monitor-exporter", targets: ["MonitorExporter"]),`. Targets:
```swift
.executableTarget(
    name: "MonitorExporter",
    dependencies: [
        "MonitorPrometheus", "MonitorSources", "MonitorCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]),
```
Add `"MonitorExporter"` to the existing `CommandLineTests` target's `dependencies`.

- [ ] **Step 2 — write the failing test** `Tests/CommandLineTests/MonitorExporterArgumentTests.swift`:
```swift
import ArgumentParser
@testable import MonitorExporter
import Testing

@Suite("monitor-exporter arguments")
struct MonitorExporterArgumentTests {
    @Test("defaults are the free port and loopback")
    func defaults() throws {
        let command = try MonitorExporterCommand.parse([])
        #expect(command.bindPort == 9650)
        #expect(command.bindAddress == "127.0.0.1")
    }

    @Test("both flags are accepted with their values")
    func flags() throws {
        let command = try MonitorExporterCommand.parse(["--bind-port", "9700", "--bind-address", "0.0.0.0"])
        #expect(command.bindPort == 9700)
        #expect(command.bindAddress == "0.0.0.0")
    }

    @Test("an unrecognised flag is rejected", arguments: ["--nonsense", "--bindport", "-x"])
    func unknownFlagRejected(_ flag: String) {
        #expect(throws: (any Error).self) { try MonitorExporterCommand.parse([flag, "1"]) }
    }

    @Test("port zero is rejected — a scrape target needs a fixed port")
    func portZeroRejected() {
        #expect(throws: (any Error).self) { try MonitorExporterCommand.parse(["--bind-port", "0"]) }
    }

    @Test("`help` as a bare word becomes --help")
    func helpWord() {
        #expect(MonitorExporter.arguments(rewriting: ["help"]) == ["--help"])
        #expect(MonitorExporter.arguments(rewriting: ["--bind-port", "9650"]) == ["--bind-port", "9650"])
    }
}
```

- [ ] **Step 3 — run, expect FAIL** (`swift test --filter "monitor-exporter arguments"`).

- [ ] **Step 4 — implement** `Sources/MonitorExporter/MonitorExporter.swift`:
```swift
import ArgumentParser
import Foundation
import MonitorCore
import MonitorSources

/// A headless daemon that serves the macOS SMC and GPU sensors as Prometheus
/// metrics on GET /metrics, for a Prometheus server to scrape.
///
/// It reads the sensors at scrape time, so the scrape interval is the sampling
/// rate — there is no interval to configure. It exports only what node_exporter
/// cannot read on macOS: SMC temperatures, fans and power, and the GPU.
///
/// The flags are declared, not parsed — the reason set out in monitord's
/// Monitord.swift (#48): a hand-rolled scan let `--help` reach the start path.
struct MonitorExporterCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor-exporter",
        abstract: "Serve macOS SMC and GPU sensors as Prometheus metrics.",
        discussion: """
        Exposes GET /metrics for a Prometheus server to scrape. Exports only \
        what node_exporter does not read on macOS: SMC temperatures, fans and \
        power, and the GPU. A sensor this machine does not have produces no \
        series rather than a zero.
        """,
        version: MonitorVersion.detailed)

    @Option(name: .customLong("bind-port"),
            help: ArgumentHelp("TCP port to listen on.", valueName: "port"))
    var bindPort: UInt16 = 9650

    @Option(name: .customLong("bind-address"),
            help: ArgumentHelp("Address to bind. 0.0.0.0 exposes it to the LAN.", valueName: "addr"))
    var bindAddress: String = "127.0.0.1"

    /// The sources this exports: the macOS gap node_exporter cannot read.
    static let gapSourceIDs = ["sensors", "gpu"]

    func validate() throws {
        guard bindPort > 0 else {
            throw ValidationError("--bind-port must be a fixed port, not 0.")
        }
    }

    func run() throws {
        // Task 5 replaces this body with the server. For now it proves the
        // sources resolve and the front door works.
        let sources = SourceRegistry.make(ids: Self.gapSourceIDs)
        print("monitor-exporter: \(sources.count) source(s) ready on \(bindAddress):\(bindPort)")
    }
}

@main
enum MonitorExporter {
    static func main() {
        MonitorExporterCommand.main(arguments(rewriting: Array(CommandLine.arguments.dropFirst())))
    }

    /// `help` as a bare word, alongside `--help` — same rewrite as monitord.
    static func arguments(rewriting arguments: [String]) -> [String] {
        arguments == ["help"] ? ["--help"] : arguments
    }
}
```

- [ ] **Step 5 — run, expect PASS**; then `swift run monitor-exporter --help` prints usage and exits.
- [ ] **Step 6 — commit:** `feat: monitor-exporter command and front door (#58)`

---

### Task 4: MetricsHandler — read sources at scrape time

**Files:**
- Modify: `Package.swift` (add `MonitorExporterTests` target)
- Create: `Sources/MonitorExporter/MetricsHandler.swift`
- Test: `Tests/MonitorExporterTests/MetricsHandlerTests.swift`

**Interfaces:**
- Consumes: `PrometheusMapping.map`, `PrometheusFamilyBuilder.families`, `renderExposition` (Tasks 1–2); `MonitorCore` (`MetricSource`, `SampleBatch`, `Sample`, `MetricID`, `MonitorVersion`, `BuildStamp`).
- Produces: `final class MetricsHandler { init(sources: [any MetricSource]); func exposition(now: TimeInterval = ...) -> String }`.

- [ ] **Step 1 — Package.swift.** Targets:
```swift
.testTarget(
    name: "MonitorExporterTests",
    dependencies: ["MonitorExporter", "MonitorCore", "MonitorPrometheus"]),
```

- [ ] **Step 2 — write the failing test** `Tests/MonitorExporterTests/MetricsHandlerTests.swift`:
```swift
import Foundation
import MonitorCore
@testable import MonitorExporter
import Testing

/// A source whose reading is fixed, so the handler can be tested without hardware.
private struct FakeSource: MetricSource {
    let id = "fake"
    var descriptors: [MetricDescriptor] { [] }
    let batch: SampleBatch?
    func read(at timestamp: TimeInterval) throws -> SampleBatch {
        guard let batch else { throw MetricSourceError.unavailable("fake") }
        return batch
    }
}

@Suite("Metrics handler")
struct MetricsHandlerTests {
    @Test("maps known sensors, drops unmapped metrics, and always emits build_info")
    func exposition() {
        let batch = SampleBatch(timestamp: 0, samples: [
            Sample(metric: MetricID("sensor.temperature.cpu"), timestamp: 0, value: 72.33),
            Sample(metric: MetricID("cpu.total"), timestamp: 0, value: 0.1),
        ])
        let text = MetricsHandler(sources: [FakeSource(batch: batch)]).exposition(now: 0)
        #expect(text.contains(#"macos_smc_temperature_celsius{sensor="cpu"} 72.33"#))
        #expect(!text.contains("cpu.total"))
        #expect(text.contains("monitor_exporter_build_info"))
    }

    @Test("a source that cannot read contributes no series — never a zero")
    func failingSource() {
        let text = MetricsHandler(sources: [FakeSource(batch: nil)]).exposition(now: 0)
        #expect(!text.contains("macos_"))
        #expect(text.contains("monitor_exporter_build_info")) // build_info still answers
    }
}
```

- [ ] **Step 3 — run, expect FAIL** (`swift test --filter "Metrics handler"`).

- [ ] **Step 4 — implement** `Sources/MonitorExporter/MetricsHandler.swift`:
```swift
import Foundation
import MonitorCore
import MonitorPrometheus

/// Reads the sensor sources once per scrape and renders the /metrics body.
///
/// Locked: a source such as SMCSource holds a single IOKit connection, and two
/// overlapping scrapes must not read it at the same time.
final class MetricsHandler: @unchecked Sendable {
    private let sources: [any MetricSource]
    private let lock = NSLock()

    init(sources: [any MetricSource]) {
        self.sources = sources
    }

    /// The full /metrics body for one scrape. A source that throws, or a metric
    /// that does not map, contributes nothing — gap, never zero.
    func exposition(now: TimeInterval = Date().timeIntervalSince1970) -> String {
        lock.lock()
        defer { lock.unlock() }

        var entries: [(MappedMetric, Double)] = []
        for source in sources {
            guard let batch = try? source.read(at: now) else { continue }
            for sample in batch.samples {
                guard let mapped = PrometheusMapping.map(sample.metric) else { continue }
                entries.append((mapped, sample.value))
            }
        }
        var families = PrometheusFamilyBuilder.families(from: entries)
        families.append(Self.buildInfo)
        return renderExposition(families)
    }

    /// A constant series carrying the build, so a scrape says which binary answered.
    static let buildInfo = PrometheusFamily(
        name: "monitor_exporter_build_info",
        help: "Build information; the value is always 1.",
        samples: [PrometheusSample(
            labels: [
                PrometheusLabel(name: "version", value: MonitorVersion.string),
                PrometheusLabel(name: "commit", value: BuildStamp.commit),
            ],
            value: 1)])
}
```

- [ ] **Step 5 — run, expect PASS.** Also confirm on this fanless Air: `swift run monitor-exporter`-side, the handler over the real `sensors`/`gpu` sources omits `macos_smc_fan_rpm` (verified end-to-end in Task 5's endpoint check).
- [ ] **Step 6 — commit:** `feat: read sensors at scrape time and render the body (#58)`

---

### Task 5: MetricsServer — NWListener on GET /metrics, and wire run()

**Files:**
- Create: `Sources/MonitorExporter/MetricsServer.swift`
- Modify: `Sources/MonitorExporter/MonitorExporter.swift` (`run()` starts the server)
- Test: `Tests/MonitorExporterTests/MetricsServerTests.swift`

**Interfaces:**
- Produces: `final class MetricsServer { init(host: String, port: UInt16, body: @escaping @Sendable () -> String) throws; func start(); func stop(); var port: UInt16? }`; static `func route(request: String, body: () -> String) -> String`.

- [ ] **Step 1 — write the failing test** `Tests/MonitorExporterTests/MetricsServerTests.swift`:
```swift
import Foundation
@testable import MonitorExporter
import Testing

@Suite("Metrics server")
struct MetricsServerTests {
    @Test("GET /metrics returns 200 with the Prometheus content type and body")
    func metricsRoute() {
        let response = MetricsServer.route(request: "GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n") { "BODY\n" }
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("Content-Type: text/plain; version=0.0.4; charset=utf-8"))
        #expect(response.hasSuffix("\r\n\r\nBODY\n"))
    }

    @Test("a metrics request with a query string still matches")
    func metricsWithQuery() {
        #expect(MetricsServer.route(request: "GET /metrics?x=1 HTTP/1.1\r\n\r\n") { "B" }.hasPrefix("HTTP/1.1 200"))
    }

    @Test("any other path is a 404", arguments: ["GET / HTTP/1.1\r\n\r\n", "POST /metrics HTTP/1.1\r\n\r\n", "GET /healthz HTTP/1.1\r\n\r\n"])
    func notFound(_ request: String) {
        #expect(MetricsServer.route(request: request) { "B" }.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    }

    @Test("a running server answers a real scrape on its bound port")
    func realScrape() async throws {
        let server = try MetricsServer(host: "127.0.0.1", port: 0) { "# TYPE x gauge\nx 1\n" }
        server.start()
        defer { server.stop() }

        var port: UInt16?
        for _ in 0..<100 where port == nil {
            port = server.port
            if port == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let bound = try #require(port)
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(bound)/metrics")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)?.contains("x 1") == true)
    }
}
```

- [ ] **Step 2 — run, expect FAIL** (`swift test --filter "Metrics server"`).

- [ ] **Step 3 — implement** `Sources/MonitorExporter/MetricsServer.swift`:
```swift
import Foundation
import Network

enum ExporterError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    var description: String {
        switch self {
        case let .invalidPort(port): "not a valid TCP port: \(port)"
        }
    }
}

/// A minimal HTTP server for one route: GET /metrics.
///
/// A whole web framework is a lot for one read-only endpoint, so this is an
/// NWListener and a hand-written response line. The routing is a pure static
/// function so it can be tested without binding a socket.
final class MetricsServer: @unchecked Sendable {
    private let listener: NWListener
    private let body: @Sendable () -> String
    private let queue = DispatchQueue(label: "wtf.evan.monitor.exporter.server")

    init(host: String, port: UInt16, body: @escaping @Sendable () -> String) throws {
        self.body = body
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ExporterError.invalidPort(port) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        listener = try NWListener(using: parameters)
    }

    /// The bound port once the listener is ready; nil before then. With port 0
    /// this is the OS-assigned ephemeral port, which the tests read.
    var port: UInt16? { listener.port?.rawValue }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let response = MetricsServer.route(request: request, body: self.body)
            connection.send(content: Data(response.utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Route one request line. GET /metrics (optionally with a query) is 200;
    /// everything else is 404.
    static func route(request: String, body: () -> String) -> String {
        let requestLine = request.components(separatedBy: "\r\n").first ?? ""
        let tokens = requestLine.split(separator: " ")
        let method = tokens.first.map(String.init) ?? ""
        let path = tokens.count >= 2 ? String(tokens[1]) : ""
        let isMetrics = method == "GET" && (path == "/metrics" || path.hasPrefix("/metrics?"))
        if isMetrics {
            return httpResponse(status: "200 OK",
                                contentType: "text/plain; version=0.0.4; charset=utf-8",
                                body: body())
        }
        return httpResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: "not found\n")
    }

    private static func httpResponse(status: String, contentType: String, body: String) -> String {
        let length = Data(body.utf8).count
        return "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(length)\r\n"
            + "Connection: close\r\n\r\n"
            + body
    }
}
```

- [ ] **Step 4 — wire `run()`** in `MonitorExporter.swift`, replacing the placeholder body:
```swift
    func run() throws {
        let sources = SourceRegistry.make(ids: Self.gapSourceIDs)
        let handler = MetricsHandler(sources: sources)
        let server = try MetricsServer(host: bindAddress, port: bindPort) { handler.exposition() }
        server.start()
        print("monitor-exporter: serving /metrics on \(bindAddress):\(bindPort)")
        RunLoop.main.run()
    }
```

- [ ] **Step 5 — run, expect PASS** (`swift test --filter "Metrics server"`). Then end-to-end on this Air:
```bash
swift build --product monitor-exporter
"$(swift build --product monitor-exporter --show-bin-path)/monitor-exporter" --bind-port 9650 &
pid=$!; sleep 1
curl -fsS http://127.0.0.1:9650/metrics | tee /dev/stderr | grep -q monitor_exporter_build_info
# Expect: temperature/power series present; macos_smc_fan_rpm ABSENT (fanless Air).
kill $pid
```
- [ ] **Step 6 — commit:** `feat: serve /metrics over NWListener and wire the daemon (#58)`

---

### Task 6: CI smoke, release zip, and docs

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `Scripts/make-app.sh`
- Modify: `README.md`, `AGENTS.md`
- Create: `docs/exporter.md`

- [ ] **Step 1 — CI.** In `ci.yml`, add `monitor-exporter` to the help/version loop in the "Smoke test CLI help and version" step (`for binary in monitorctl monitord monitor-exporter`), add `! swift run -c release monitor-exporter --nonsense`, and add a new step that boots the endpoint and scrapes it once:
```yaml
      - name: Smoke test the exporter endpoint
        run: |
          set -euo pipefail
          swift build -c release --product monitor-exporter
          bin="$(swift build -c release --product monitor-exporter --show-bin-path)/monitor-exporter"
          "$bin" --bind-port 9650 &
          pid=$!
          trap 'kill "$pid" 2>/dev/null || true' EXIT
          sleep 2
          body="$(curl -fsS http://127.0.0.1:9650/metrics)"
          echo "$body"
          echo "$body" | grep -q monitor_exporter_build_info
          # The runner is an M-series Mac with fans, so the full set is present.
          echo "$body" | grep -q 'macos_smc_temperature_celsius{sensor="cpu"}'
```
- [ ] **Step 2 — release zip.** In `Scripts/make-app.sh`, mirror the monitord block for `monitor-exporter`: build `--product monitor-exporter`, sign it the same way monitord is signed, and `cp` it into `$package/monitor-exporter`. Update the staging echo to `(monitor.app, monitord, monitor-exporter)`. Update the comment in `package.yml`'s Package step to list the third binary.
- [ ] **Step 3 — docs.** Add a `monitor-exporter` section to `README.md` (what it is, `--bind-port`/`--bind-address`, the metric names, "gap only; node_exporter covers CPU/mem/disk/net", the scrape-config snippet) and to `AGENTS.md` (new binary, its target/module, the gap-only scope). Create `docs/exporter.md` with a launchd `LaunchAgent` plist example that runs `monitor-exporter --bind-port 9650` and a Prometheus `scrape_configs` job pointing at `127.0.0.1:9650`.
- [ ] **Step 4 — full gate:** `swift build && swift test && swift build -c release && swiftformat Sources Tests Plugins --lint --cache ignore`. Expect all green, no format diffs.
- [ ] **Step 5 — commit:** `ci: smoke-test the exporter; ship it in the release zip; document it (#58)`

---

## Self-Review

- **Spec coverage:** own-port /metrics (Tasks 3–5); gap-only scope enforced by `SourceRegistry.make(ids:)` + mapping returning nil (Tasks 2, 4); `macos_smc_*`/`macos_gpu_*` names, °C-only, no hostname label (Task 2); `--bind-port 9650`/`--bind-address` (Task 3); gap-not-zero (Tasks 1 empty-family, 4 failing-source); build_info (Task 4); no new dependency (in-house renderer, NWListener); CI + zip + docs (Task 6). `--all` intentionally out of scope.
- **Placeholder scan:** none — every step carries real code or an exact edit. The one deliberately-incremental piece (Task 3 `run()`) is called out and replaced in Task 5.
- **Type consistency:** `MappedMetric`, `PrometheusFamily`, `MetricsHandler.exposition(now:)`, `MetricsServer.route(request:body:)` and `MonitorExporterCommand.bindPort/bindAddress` are used with the same signatures across tasks.
```

