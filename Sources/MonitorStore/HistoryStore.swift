import Foundation
import MonitorCore

/// How long samples are kept, and at what resolution.
///
/// This is not an archive. The question the app answers is "what just
/// happened?" — a blip five minutes ago, or the thing that woke the fans at
/// 3am last night. Keeping a week of one-second samples for thirty metrics is
/// roughly 18 million rows and answers no question that a ten-second average
/// does not, so resolution degrades with age instead.
///
/// Each tier names the age at which raw samples are rolled up into buckets of
/// `interval` seconds. Beyond the last tier, samples are deleted.
public struct RetentionPolicy: Sendable, Hashable {
    public struct Tier: Sendable, Hashable {
        /// Samples older than this are rolled up.
        public let age: TimeInterval
        /// Bucket width to roll them up into.
        public let interval: TimeInterval

        public init(age: TimeInterval, interval: TimeInterval) {
            self.age = age
            self.interval = interval
        }
    }

    /// Ordered by increasing age.
    public let tiers: [Tier]
    /// Samples older than this are deleted outright.
    public let horizon: TimeInterval

    public init(tiers: [Tier], horizon: TimeInterval) {
        self.tiers = tiers.sorted { $0.age < $1.age }
        self.horizon = horizon
    }

    /// Full resolution for an hour, ten-second buckets for a day, one-minute
    /// buckets out to a week. About 250 MB becomes about 12 MB.
    public static let week = RetentionPolicy(
        tiers: [
            Tier(age: 3600, interval: 10),
            Tier(age: 86400, interval: 60),
        ],
        horizon: 7 * 86400
    )

    /// For a machine where a week is more than anyone will scroll back through.
    public static let day = RetentionPolicy(
        tiers: [Tier(age: 3600, interval: 10)],
        horizon: 86400
    )
}

/// A window of history for one metric, already reduced to what a chart needs.
public struct HistoryQuery: Sendable, Hashable {
    public let metrics: [MetricID]
    public let start: TimeInterval
    public let end: TimeInterval
    /// Bucket width to return. The store aggregates further if its stored rows
    /// are finer than this; it never interpolates to make them finer.
    public let interval: TimeInterval

    public init(
        metrics: [MetricID],
        start: TimeInterval,
        end: TimeInterval,
        interval: TimeInterval
    ) {
        self.metrics = metrics
        self.start = start
        self.end = end
        self.interval = interval
    }
}

/// Persistence for samples.
///
/// A protocol rather than a concrete type because the tests must not need a
/// file, and because the app and the daemon reach the same data by different
/// routes: the daemon writes, the app reads.
public protocol HistoryStore: Sendable {
    func write(_ batch: SampleBatch) throws
    func read(_ query: HistoryQuery) throws -> [MetricID: [Bucket]]
    /// Apply the retention policy: roll up what is old, delete what is older.
    /// Called on a slow timer, not on every write.
    func compact(policy: RetentionPolicy, now: TimeInterval) throws
    /// Metrics that have at least one stored sample.
    func knownMetrics() throws -> [MetricID]
}
