import Foundation

/// How much moved over a window, from the rates that were sampled across it.
///
/// The dials answer "how hard is this working right now" and the charts answer
/// "what has been happening". Neither answers "how much did that transfer
/// cost me", which is the question you have while watching a sync run.
///
/// **A rate sample is the mean over the gap before it.** `RateTracker` produces
/// `Δcounter / Δt`, so multiplying each sample by the interval it measures and
/// summing telescopes back to exactly the counter delta the window covers. That
/// is the whole trick: no counter history is kept anywhere, no source changes,
/// and nothing is read that the ring buffer does not already hold.
///
/// In `MonitorCore` beside `CSVExport` and the preference models, for the same
/// reason they are: the interesting part is arithmetic, and arithmetic should
/// not need a machine to read or a window to draw in.
public enum WindowTotal {
    /// A total, and how much of the window it actually accounts for.
    ///
    /// The second half is not decoration. Ten seconds after launch the buffer
    /// holds ten seconds, and putting "2 min" under a number covering a twelfth
    /// of that is the quiet kind of wrong — nobody checks it, because it looks
    /// exactly like the right answer.
    public struct Result: Equatable, Sendable {
        /// The counter delta, in the rate's unit times seconds. Bytes for
        /// `bytesPerSecond`, bits for `bitsPerSecond`, operations for
        /// `operationsPerSecond`. Converting to what a reader wants is
        /// `MetricUnit.accumulation`'s job, not this one's.
        public let value: Double
        /// Seconds of the window the samples account for. At most `window`,
        /// and less when history is short or an interval was clipped.
        public let covered: TimeInterval

        public init(value: Double, covered: TimeInterval) {
            self.value = value
            self.covered = covered
        }
    }

    /// The total across `window` seconds ending at `now`.
    ///
    /// - Parameters:
    ///   - points: the series' samples. Sorted here rather than assumed sorted,
    ///     because a total that depends on array order is a bug waiting for a
    ///     refactor.
    ///   - window: seconds of history to add up — the same window the card is
    ///     drawing, so the number and the picture answer the same question.
    ///   - now: the right-hand edge. Defaults to the newest sample, which is
    ///     the rule `CSVExport` already follows.
    ///   - maximumGap: the widest interval one sample may be credited with. A
    ///     slept laptop or a source that failed for a minute leaves one
    ///     enormous gap, and a rectangle drawn across it invents traffic that
    ///     never happened. The caller knows the sampling clock; this does not.
    /// - Returns: nil when there are fewer than two samples. There is genuinely
    ///   no total yet — the same answer `RateTracker` gives on a first read,
    ///   and for the same reason: zero would draw as an idle machine rather
    ///   than as a missing number.
    public static func total(
        of points: [Sample],
        window: TimeInterval,
        now: TimeInterval? = nil,
        maximumGap: TimeInterval
    ) -> Result? {
        guard points.count >= 2 else { return nil }
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        guard let end = now ?? sorted.last?.timestamp else { return nil }
        let start = end - window

        var value = 0.0
        var covered = 0.0
        // From the second sample: the oldest one has no predecessor, so the
        // width of its interval is unknown and it is credited with nothing.
        // Reaching back to the window's edge instead would invent history in
        // exactly the case where there is none.
        for index in 1..<sorted.count {
            let sample = sorted[index]
            guard sample.timestamp > start, sample.timestamp <= end else { continue }
            // The predecessor may sit outside the window. That is deliberate:
            // it is what makes the leading partial interval come out clipped
            // rather than dropped whole.
            let previous = max(sorted[index - 1].timestamp, start)
            let interval = min(sample.timestamp - previous, maximumGap)
            guard interval > 0 else { continue }
            value += sample.value * interval
            covered += interval
        }
        return Result(value: value, covered: covered)
    }
}
