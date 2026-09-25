import Foundation

/// How a spiky card is calmed down, and over how long.
///
/// Some series switch between idle and flat out every second or two. The GPU
/// and the power draw under a bursty load are the worst of them: 1,200 samples
/// drawn into a card a few hundred points wide leave a solid block of colour,
/// and what the machine is actually doing cannot be read off it.
///
/// **Only the picture changes.** A smoothed card still puts the raw latest
/// reading in its legend, the gauges still read the raw sample, and Copy Data
/// and the window totals still see the buffer as the source wrote it. The
/// same rule as mirroring, for the same reason: this is a way to draw the
/// numbers, not a different set of numbers.
public struct Smoothing: Codable, Hashable, Sendable {
    public var method: SmoothingMethod
    /// Seconds, never samples. The sampling rate is a preference, and sensors
    /// already run at a different rate from counters, so a count of samples
    /// would cover a different span on every card.
    public var window: TimeInterval

    public init(method: SmoothingMethod, window: TimeInterval) {
        self.method = method
        self.window = window
    }

    /// The windows on offer. Five seconds takes the edge off a comb; a minute
    /// shows the trend under a load that never settles.
    public static let windows: [TimeInterval] = [5, 15, 60]

    /// The window a card gets when smoothing is switched on from off: long
    /// enough to calm a comb, short enough that the line still follows a load.
    public static let defaultWindow: TimeInterval = 15

    /// The value a card draws its line at.
    ///
    /// The band's line is its mean: the band says how far the series swung, and
    /// the line inside it says where it sat on average.
    public func line(_ point: RollingPoint) -> Double {
        switch method {
        case .mean, .band: point.mean
        case .median: point.median
        }
    }

    /// Whether the card draws a min...max band behind the line.
    public var drawsBand: Bool { method == .band }
}

public enum SmoothingMethod: String, Codable, CaseIterable, Sendable {
    /// A rolling average. Spreads a spike across the window.
    case mean
    /// A rolling median. Drops a lone spike outright, which is what a card
    /// wants when one outlier is noise rather than the event to see.
    case median
    /// The window's minimum to maximum as a band, with the mean as a line. A
    /// spike stays visible at full height, and a load that switches on and off
    /// reads as switching rather than as a steady level it never held.
    case band

    /// Whether a stacked card may use it.
    ///
    /// Only the mean. It is linear, so the smoothed slices still add up to the
    /// smoothed aggregate drawn over them. A median is not: the medians of the
    /// slices do not sum to the median of the whole, and Memory Used would
    /// float off the stack it is meant to sit on. A band per slice on top of
    /// stacked bands is unreadable.
    public var isStackable: Bool { self == .mean }
}

/// One sample's trailing window, summarised.
public struct RollingPoint: Hashable, Sendable {
    /// The sample's own timestamp. The window ends here.
    public let timestamp: TimeInterval
    public let mean: Double
    public let median: Double
    public let minimum: Double
    public let maximum: Double

    public init(
        timestamp: TimeInterval,
        mean: Double,
        median: Double,
        minimum: Double,
        maximum: Double
    ) {
        self.timestamp = timestamp
        self.mean = mean
        self.median = median
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// Trailing-window statistics over a series.
///
/// Beside `Downsample` rather than built on it. `Downsample` cuts time into
/// fixed buckets, which suits a store read back at a day's range; a live chart
/// wants a point per sample, so the line moves as smoothly as the data arrives
/// instead of stepping once per bucket.
public enum Rolling {
    /// One point per sample, summarising the samples in `(t - window, t]`.
    ///
    /// **Trailing, not centred.** A centred window has nothing to put at the
    /// right-hand edge, which on a live chart is the edge that matters. The
    /// cost is lag: the line runs about half a window behind the samples.
    ///
    /// **Never across a gap.** Two neighbouring samples further apart than
    /// `maximumGap` start a new window. A laptop back from sleep would
    /// otherwise blend its last reading before sleep into its first after it.
    ///
    /// The mean is of samples, not weighted by time. Within a run with no gap
    /// the samples are one clock tick apart, so the two agree.
    ///
    /// - Parameters:
    ///   - samples: sorted here rather than assumed sorted, for the reason
    ///     `WindowTotal` gives.
    ///   - window: seconds; must be positive.
    ///   - maximumGap: the widest spacing still treated as one run. The caller
    ///     knows the sampling clock; this does not.
    public static func points(
        _ samples: [Sample],
        window: TimeInterval,
        maximumGap: TimeInterval
    ) -> [RollingPoint] {
        precondition(window > 0, "window must be positive")
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var result: [RollingPoint] = []
        result.reserveCapacity(sorted.count)

        // The window's values in ascending order, so the median, minimum and
        // maximum are reads rather than a sort per sample.
        var ordered: [Double] = []
        var oldest = 0

        for index in sorted.indices {
            let sample = sorted[index]
            if index > 0, sample.timestamp - sorted[index - 1].timestamp > maximumGap {
                ordered.removeAll(keepingCapacity: true)
                oldest = index
            }
            ordered.insert(sample.value, at: lowerBound(of: sample.value, in: ordered))
            while sorted[oldest].timestamp <= sample.timestamp - window {
                ordered.remove(at: lowerBound(of: sorted[oldest].value, in: ordered))
                oldest += 1
            }

            let count = ordered.count
            let middle = count / 2
            let median = count.isMultiple(of: 2)
                ? (ordered[middle - 1] + ordered[middle]) / 2
                : ordered[middle]
            result.append(
                RollingPoint(
                    timestamp: sample.timestamp,
                    mean: ordered.reduce(0, +) / Double(count),
                    median: median,
                    minimum: ordered[0],
                    maximum: ordered[count - 1]
                )
            )
        }
        return result
    }

    /// The first index whose value is not less than `value`.
    private static func lowerBound(of value: Double, in ordered: [Double]) -> Int {
        var low = 0
        var high = ordered.count
        while low < high {
            let middle = (low + high) / 2
            if ordered[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
