import Foundation

/// A stable identifier for one measured series.
///
/// The raw value is the on-disk key, so it must never change once a build has
/// written history with it. Renaming a metric orphans its stored samples.
public struct MetricID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// What a value means, which decides how a chart draws and labels it.
public enum MetricUnit: String, Sendable, Codable {
    /// 0...1. Charts fix the y-axis to that range rather than to the data.
    case fraction
    case bytes
    case bytesPerSecond
    case operationsPerSecond
    case count
    case hertz
    case celsius
    case watts
    case seconds
}

/// How consecutive samples relate to each other.
public enum MetricKind: String, Sendable, Codable {
    /// An instantaneous reading: memory in use, temperature.
    case gauge
    /// A monotonic total the source reports raw, such as bytes read since boot.
    /// The sampler differentiates it into a rate; the counter itself is never
    /// charted, because a line that only goes up says nothing.
    case counter
}

/// Everything the UI needs to draw a series without knowing where it came from.
public struct MetricDescriptor: Hashable, Sendable, Codable {
    public let id: MetricID
    /// Short label for a chart legend, e.g. "Read".
    public let name: String
    /// Group heading, e.g. "Disk". Metrics sharing a group share a chart card.
    public let group: String
    public let unit: MetricUnit
    public let kind: MetricKind
    /// Upper bound for the y-axis when the unit does not imply one. Nil means
    /// the chart scales to the data.
    public let nominalMaximum: Double?

    public init(
        id: MetricID,
        name: String,
        group: String,
        unit: MetricUnit,
        kind: MetricKind = .gauge,
        nominalMaximum: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.unit = unit
        self.kind = kind
        self.nominalMaximum = nominalMaximum
    }
}
