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
    /// Disk throughput. Always shown in MB/s — drives are quoted in bytes.
    case bytesPerSecond
    /// Network throughput. Always shown in Mbit/s — links are quoted in bits,
    /// so reporting bytes forces a division by eight on every reading.
    case bitsPerSecond
    case operationsPerSecond
    case count
    case hertz
    case celsius
    case watts
    /// Fan speed. Its own unit rather than `count`, because "3200" and
    /// "3200 rpm" are not the same reading on a chart axis.
    case rpm
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

/// Which way a flow runs, for the metrics that are one direction of one.
///
/// Disk bytes read and written, network bits and packets in and out, pages in
/// and out of memory. A metric with a direction has an opposite in its group,
/// and the two are only meaningful against each other.
///
/// A fact about the metric, not about the picture: whether the pair is then
/// *drawn* mirrored is a preference, and lives in `ChartPreferences`. Declaring
/// it here means a source added later gets the option without anything else
/// being told about it.
///
/// Most metrics have none. Read and write *latency* are the instructive case:
/// two measurements of the same kind, not two directions of one flow, so
/// neither carries a direction and their card never mirrors.
public enum MetricDirection: String, Sendable, Codable {
    /// Arriving: bytes read, packets in, pages in.
    case inbound
    /// Leaving: bytes written, packets out, pages out.
    case outbound
}

/// How a metric relates to the others in its group.
///
/// Most have no relation: two temperature sensors are two readings, and neither
/// is a slice or a sum of the other. Some groups are a whole divided up —
/// memory is app, wired, compressed, cached and free — and there stacking the
/// slices shows the total as well as the split, which lines drawn from zero
/// cannot.
///
/// A fact about the metric, like `direction`. Whether the parts are then
/// *drawn* stacked is a preference in `ChartPreferences`.
public enum MetricComposition: String, Sendable, Codable {
    /// One slice of the group's whole. Slices do not overlap, so they can be
    /// stacked.
    case part
    /// A sum of other metrics in the same group: memory Used is app plus wired
    /// plus compressed, CPU Total is user plus system. **Never stacked** — it
    /// would count its own parts a second time. Drawn as a line over the bands,
    /// where it lands exactly on top of the slices it sums.
    case aggregate
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
    /// Which way this one runs, when it is one direction of a flow. Nil for
    /// everything that is not.
    public let direction: MetricDirection?
    /// Whether this one is a slice of its group's whole, or a sum of those
    /// slices. Nil for the metrics that are neither.
    public let composition: MetricComposition?

    public init(
        id: MetricID,
        name: String,
        group: String,
        unit: MetricUnit,
        kind: MetricKind = .gauge,
        nominalMaximum: Double? = nil,
        direction: MetricDirection? = nil,
        composition: MetricComposition? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.unit = unit
        self.kind = kind
        self.nominalMaximum = nominalMaximum
        self.direction = direction
        self.composition = composition
    }
}
