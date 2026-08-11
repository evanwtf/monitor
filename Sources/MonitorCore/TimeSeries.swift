import Foundation

/// A fixed-capacity ring buffer of samples for one metric.
///
/// This is the live window the charts read from — the last few minutes at full
/// resolution. Longer ranges come from the store, not from here. Capacity is
/// fixed so a window left open for a week cannot grow without bound.
public struct TimeSeries: Sendable {
    public let metric: MetricID
    public let capacity: Int

    private var values: [Double]
    private var timestamps: [TimeInterval]
    private var head = 0
    public private(set) var count = 0

    public init(metric: MetricID, capacity: Int) {
        precondition(capacity > 0, "a time series needs room for at least one sample")
        self.metric = metric
        self.capacity = capacity
        values = Array(repeating: 0, count: capacity)
        timestamps = Array(repeating: 0, count: capacity)
    }

    public mutating func append(_ value: Double, at timestamp: TimeInterval) {
        values[head] = value
        timestamps[head] = timestamp
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    public mutating func append(_ sample: Sample) {
        append(sample.value, at: sample.timestamp)
    }

    /// Samples in time order, oldest first.
    public var points: [Sample] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        return (0..<count).map { offset in
            let index = (start + offset) % capacity
            return Sample(metric: metric, timestamp: timestamps[index], value: values[index])
        }
    }

    public var latest: Sample? {
        guard count > 0 else { return nil }
        let index = (head - 1 + capacity) % capacity
        return Sample(metric: metric, timestamp: timestamps[index], value: values[index])
    }
}
