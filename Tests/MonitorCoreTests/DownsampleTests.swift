import Foundation
@testable import MonitorCore
import Testing

@Suite("Downsample")
struct DownsampleTests {
    private func samples(_ values: [(TimeInterval, Double)]) -> [Sample] {
        values.map { Sample(metric: MetricID("m"), timestamp: $0.0, value: $0.1) }
    }

    @Test("groups samples into fixed spans")
    func buckets() {
        let result = Downsample.buckets(
            samples([(0, 1), (1, 3), (10, 5), (11, 7)]), interval: 10
        )
        #expect(result.count == 2)
        #expect(result[0].mean == 2)
        #expect(result[1].mean == 6)
    }

    /// The reason for bucketing at all: a one-second spike inside a ten-minute
    /// bucket must survive as the bucket's maximum. If it does not, the chart
    /// silently hides exactly the event the app exists to show.
    @Test("a spike survives aggregation as the bucket maximum")
    func spikeSurvives() {
        var values: [(TimeInterval, Double)] = (0..<60).map { (TimeInterval($0), 0.1) }
        values[37] = (37, 0.98)
        let result = Downsample.buckets(samples(values), interval: 60)
        #expect(result.count == 1)
        #expect(result[0].maximum == 0.98)
        #expect(result[0].minimum == 0.1)
        #expect(result[0].mean < 0.12)
    }

    /// An empty span produces no bucket, so a gap in the data stays visible
    /// rather than being interpolated over.
    @Test("leaves gaps as gaps")
    func gaps() {
        let result = Downsample.buckets(samples([(0, 1), (100, 2)]), interval: 10)
        #expect(result.count == 2)
        #expect(result[1].timestamp == 100)
    }

    @Test("handles no samples")
    func empty() {
        #expect(Downsample.buckets([], interval: 10).isEmpty)
    }

    @Test("picks a whole-second interval for a chart width")
    func interval() {
        #expect(Downsample.interval(forDuration: 600, width: 300) == 2)
        // Never finer than a second, even on a very wide chart.
        #expect(Downsample.interval(forDuration: 60, width: 1200) == 1)
    }
}
