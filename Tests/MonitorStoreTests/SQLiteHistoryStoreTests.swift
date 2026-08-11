import Foundation
import MonitorCore
@testable import MonitorStore
import Testing

/// The store is not linked into the v1 app, but it is tested, because the
/// retention behaviour is the part that is hard to get right and easy to get
/// wrong quietly.
@Suite("SQLiteHistoryStore")
struct SQLiteHistoryStoreTests {
    private func makeStore() throws -> (SQLiteHistoryStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("monitor-test-\(UUID().uuidString).sqlite")
        return try (SQLiteHistoryStore(url: url), url)
    }

    private func batch(_ metric: String, _ values: [(TimeInterval, Double)]) -> SampleBatch {
        SampleBatch(
            timestamp: values.first?.0 ?? 0,
            samples: values.map {
                Sample(metric: MetricID(metric), timestamp: $0.0, value: $0.1)
            }
        )
    }

    @Test("writes and reads back a series")
    func roundTrip() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.write(batch("cpu.total", [(100, 0.5), (101, 0.7)]))
        let result = try store.read(
            HistoryQuery(metrics: [MetricID("cpu.total")], start: 0, end: 200, interval: 1)
        )
        #expect(result[MetricID("cpu.total")]?.count == 2)
        #expect(try store.knownMetrics() == [MetricID("cpu.total")])
    }

    @Test("aggregates into the requested bucket width")
    func bucketing() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // Starting on a bucket boundary: buckets are aligned to the epoch, not
        // to the start of the query.
        let values = (0..<60).map { (TimeInterval(1200 + $0), Double($0)) }
        try store.write(batch("m", values))

        let result = try store.read(
            HistoryQuery(metrics: [MetricID("m")], start: 1200, end: 1260, interval: 60)
        )
        let buckets = try #require(result[MetricID("m")])
        #expect(buckets.count == 1)
        #expect(buckets[0].minimum == 0)
        #expect(buckets[0].maximum == 59)
        #expect(buckets[0].count == 60)
    }

    /// Bucket edges are epoch-aligned so they do not move when the query range
    /// moves. Aligning to the query start instead would make every bucket
    /// boundary shift as a chart scrolls, and the line would visibly reshuffle
    /// once a second while its underlying data was unchanged.
    @Test("bucket edges do not move with the query window")
    func bucketsAreEpochAligned() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.write(batch("m", (0..<120).map { (TimeInterval(1200 + $0), Double($0)) }))

        let wide = try store.read(
            HistoryQuery(metrics: [MetricID("m")], start: 1200, end: 1320, interval: 60)
        )
        let shifted = try store.read(
            HistoryQuery(metrics: [MetricID("m")], start: 1237, end: 1320, interval: 60)
        )
        let wideEdges = try #require(wide[MetricID("m")]).map(\.timestamp)
        let shiftedEdges = try #require(shifted[MetricID("m")]).map(\.timestamp)
        #expect(Set(shiftedEdges).isSubset(of: Set(wideEdges)))
    }

    /// Compaction must reduce the row count without moving the extremes. If a
    /// spike disappears when the data ages, the app forgets the events it
    /// exists to remember.
    @Test("compaction preserves minimum and maximum")
    func compactionKeepsExtremes() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let now: TimeInterval = 1_000_000
        var values = (0..<600).map { (now - 7200 + TimeInterval($0), 0.1) }
        values[123] = (values[123].0, 0.95)
        try store.write(batch("m", values))

        let query = HistoryQuery(
            metrics: [MetricID("m")], start: now - 8000, end: now, interval: 600
        )
        let before = try #require(try store.read(query)[MetricID("m")])

        try store.compact(policy: .week, now: now)
        let after = try #require(try store.read(query)[MetricID("m")])

        #expect(after.map(\.maximum).max() == before.map(\.maximum).max())
        #expect(after.map(\.minimum).min() == before.map(\.minimum).min())
    }

    @Test("compaction is repeatable")
    func compactionIsIdempotent() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let now: TimeInterval = 1_000_000
        try store.write(batch("m", (0..<600).map { (now - 7200 + TimeInterval($0), 0.4) }))

        let query = HistoryQuery(
            metrics: [MetricID("m")], start: now - 8000, end: now, interval: 10
        )
        try store.compact(policy: .week, now: now)
        let once = try #require(try store.read(query)[MetricID("m")]).count
        try store.compact(policy: .week, now: now)
        let twice = try #require(try store.read(query)[MetricID("m")]).count
        #expect(once == twice, "re-running compaction kept smearing the data")
    }

    @Test("deletes samples past the horizon")
    func horizon() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let now: TimeInterval = 1_000_000
        try store.write(batch("m", [(now - 8 * 86400, 1), (now - 60, 2)]))
        try store.compact(policy: .week, now: now)

        let result = try store.read(
            HistoryQuery(metrics: [MetricID("m")], start: 0, end: now, interval: 1)
        )
        #expect(result[MetricID("m")]?.count == 1)
    }
}
