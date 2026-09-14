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
