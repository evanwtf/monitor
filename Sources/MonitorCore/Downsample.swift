import Foundation

/// Reduces a long span of samples to a chart's worth of buckets.
///
/// A day of one-second samples is 86,400 points and a chart is perhaps 1,200
/// pixels wide. Drawing all of them is slow and, worse, dishonest: whichever
/// sample the renderer happens to land on wins, so a one-second spike appears
/// or vanishes depending on the window width.
///
/// So each bucket keeps minimum, maximum and mean. The chart draws the mean as
/// a line and min...max as a band, and a spike stays visible at every zoom
/// level. This is the difference between a chart that can be read at a day's
/// range and one that cannot.
public struct Bucket: Sendable, Hashable {
    /// Start of the bucket's time span.
    public let timestamp: TimeInterval
    public let minimum: Double
    public let maximum: Double
    public let mean: Double
    public let count: Int

    public init(
        timestamp: TimeInterval,
        minimum: Double,
        maximum: Double,
        mean: Double,
        count: Int
    ) {
        self.timestamp = timestamp
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
        self.count = count
    }
}

public enum Downsample {
    /// Bucket `samples` into fixed-width spans of `interval` seconds.
    ///
    /// Input must be sorted by timestamp, which is what both the ring buffer
    /// and the store return. Empty spans produce no bucket, so a gap in the
    /// data stays a gap instead of being interpolated over.
    public static func buckets(_ samples: [Sample], interval: TimeInterval) -> [Bucket] {
        precondition(interval > 0, "bucket interval must be positive")
        guard let first = samples.first else { return [] }

        var result: [Bucket] = []
        let origin = (first.timestamp / interval).rounded(.down) * interval

        var spanStart = origin
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var total = 0.0
        var count = 0

        func flush() {
            guard count > 0 else { return }
            result.append(
                Bucket(
                    timestamp: spanStart,
                    minimum: minimum,
                    maximum: maximum,
                    mean: total / Double(count),
                    count: count
                )
            )
            minimum = .infinity
            maximum = -.infinity
            total = 0
            count = 0
        }

        for sample in samples {
            let start = ((sample.timestamp - origin) / interval)
                .rounded(.down) * interval + origin
            if start != spanStart {
                flush()
                spanStart = start
            }
            minimum = Swift.min(minimum, sample.value)
            maximum = Swift.max(maximum, sample.value)
            total += sample.value
            count += 1
        }
        flush()
        return result
    }

    /// Bucket interval that fills `width` points over a span of `duration`.
    /// Snapped to a whole number of seconds so bucket edges stay stable as the
    /// window resizes; otherwise the chart reshuffles on every drag.
    public static func interval(forDuration duration: TimeInterval,
                                width: Int) -> TimeInterval
    {
        guard width > 0, duration > 0 else { return 1 }
        return Swift.max(1, (duration / Double(width)).rounded(.up))
    }
}
