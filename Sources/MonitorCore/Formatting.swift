import Foundation

/// Turns a raw value into what a gauge or an axis shows.
///
/// Centralised because the same number appears in a gauge readout, a tick
/// label, a chart axis and `monitorctl` output, and they must agree. A gauge
/// reading 480 MB/s beside an axis reading 0.48 GB/s looks like a bug.
public enum Format {
    /// Decimal units (kB = 1000), matching how Apple reports disk and network
    /// throughput. Mixing these with binary units is where "my 500 MB/s SSD"
    /// arguments come from, so the app picks one and stays with it.
    public static func bytes(_ value: Double, perSecond: Bool = false) -> String {
        let suffix = perSecond ? "/s" : ""
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        var magnitude = abs(value)
        var index = 0
        while magnitude >= 1000, index < units.count - 1 {
            magnitude /= 1000
            index += 1
        }
        let digits = magnitude < 10 && index > 0 ? 1 : 0
        return "\(String(format: "%.\(digits)f", magnitude)) \(units[index])\(suffix)"
    }

    public static func fraction(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    public static func rate(_ value: Double, unit: String = "/s") -> String {
        if value >= 1000 { return "\(Int(value.rounded()))\(unit)" }
        if value >= 10 { return String(format: "%.0f%@", value, unit) }
        return String(format: "%.1f%@", value, unit)
    }

    public static func duration(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.2f s", seconds) }
        if seconds >= 0.001 { return String(format: "%.1f ms", seconds * 1000) }
        return String(format: "%.0f µs", seconds * 1_000_000)
    }

    /// Format a value according to its metric's unit.
    public static func value(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .fraction: fraction(value)
        case .bytes: bytes(value)
        case .bytesPerSecond: bytes(value, perSecond: true)
        case .operationsPerSecond: rate(value)
        case .count: rate(value, unit: "")
        case .hertz: rate(value, unit: " Hz")
        case .celsius: String(format: "%.0f °C", value)
        case .watts: String(format: "%.1f W", value)
        case .seconds: duration(value)
        }
    }

    /// The unit shown under a gauge's digital readout, e.g. "MB/s". Separate
    /// from the number because the gauge draws them in different type sizes.
    public static func unitLabel(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .bytes, .bytesPerSecond:
            let text = bytes(value, perSecond: unit == .bytesPerSecond)
            return text.split(separator: " ").last.map(String.init) ?? ""
        case .fraction: return "%"
        case .operationsPerSecond: return "IO/s"
        case .seconds: return value >= 1 ? "s" : (value >= 0.001 ? "ms" : "µs")
        case .count: return ""
        case .hertz: return "Hz"
        case .celsius: return "°C"
        case .watts: return "W"
        }
    }

    /// Just the number part, for a gauge readout whose unit is drawn separately.
    public static func magnitude(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .bytes, .bytesPerSecond:
            let text = bytes(value, perSecond: false)
            return text.split(separator: " ").first.map(String.init) ?? "0"
        case .fraction: return "\(Int((value * 100).rounded()))"
        case .seconds:
            if value >= 1 { return String(format: "%.2f", value) }
            if value >= 0.001 { return String(format: "%.1f", value * 1000) }
            return String(format: "%.0f", value * 1_000_000)
        default: return rate(value, unit: "")
        }
    }
}
