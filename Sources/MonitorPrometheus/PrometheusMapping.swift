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
            return MappedMetric(
                familyName: "macos_gpu_utilization_ratio", help: gpuUtilizationHelp, labels: []
            )
        case "gpu.vram.used":
            return MappedMetric(
                familyName: "macos_gpu_vram_used_bytes", help: gpuVramHelp, labels: []
            )
        default:
            guard let index = fanIndex(id.rawValue) else { return nil }
            return MappedMetric(
                familyName: "macos_smc_fan_rpm", help: fanHelp,
                labels: [PrometheusLabel(name: "fan", value: String(index))]
            )
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
        MappedMetric(
            familyName: "macos_smc_temperature_celsius", help: temperatureHelp,
            labels: [PrometheusLabel(name: "sensor", value: sensor)]
        )
    }

    private static func power(_ rail: String) -> MappedMetric {
        MappedMetric(
            familyName: "macos_smc_power_watts", help: powerHelp,
            labels: [PrometheusLabel(name: "rail", value: rail)]
        )
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
                samples: body.samples
                    .sorted { renderLabels($0.labels) < renderLabels($1.labels) }
            )
        }
    }
}
