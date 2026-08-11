import Foundation

/// One reading of one metric.
public struct Sample: Hashable, Sendable, Codable {
    public let metric: MetricID
    /// Seconds since the Unix epoch. A `Double` rather than a `Date` because
    /// this is what goes into the store and into a chart's x-axis, and because
    /// millions of them exist at once.
    public let timestamp: TimeInterval
    public let value: Double

    public init(metric: MetricID, timestamp: TimeInterval, value: Double) {
        self.metric = metric
        self.timestamp = timestamp
        self.value = value
    }
}

/// Everything read in one tick of the sampling clock.
///
/// Sources return a batch rather than a value at a time so that all the metrics
/// derived from a single system call share one timestamp. Per-core CPU load is
/// one `host_processor_info` call; the cores must not drift apart on the x-axis.
public struct SampleBatch: Sendable {
    public let timestamp: TimeInterval
    public let samples: [Sample]

    public init(timestamp: TimeInterval, values: [MetricID: Double]) {
        self.timestamp = timestamp
        samples = values.map { Sample(metric: $0.key, timestamp: timestamp, value: $0.value) }
    }

    public init(timestamp: TimeInterval, samples: [Sample]) {
        self.timestamp = timestamp
        self.samples = samples
    }
}
