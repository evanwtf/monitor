import Foundation
@testable import MonitorCore
import Testing

@Suite("TimeSeries")
struct TimeSeriesTests {
    @Test("keeps samples in time order")
    func ordering() {
        var series = TimeSeries(metric: MetricID("t"), capacity: 4)
        for index in 0..<3 { series.append(Double(index), at: Double(index)) }
        #expect(series.points.map(\.value) == [0, 1, 2])
        #expect(series.latest?.value == 2)
    }

    @Test("drops the oldest sample once full")
    func wraps() {
        var series = TimeSeries(metric: MetricID("t"), capacity: 3)
        for index in 0..<5 { series.append(Double(index), at: Double(index)) }
        #expect(series.count == 3)
        #expect(series.points.map(\.value) == [2, 3, 4])
    }

    @Test("is empty before anything is appended")
    func empty() {
        let series = TimeSeries(metric: MetricID("t"), capacity: 3)
        #expect(series.points.isEmpty)
        #expect(series.latest == nil)
    }
}

@Suite("RateTracker")
struct RateTrackerTests {
    @Test("produces no rate from a single reading")
    func firstReading() {
        var tracker = RateTracker()
        #expect(tracker.rate(for: MetricID("c"), total: 100, at: 1) == nil)
    }

    @Test("differentiates a counter into a per-second rate")
    func rate() {
        var tracker = RateTracker()
        let metric = MetricID("c")
        _ = tracker.rate(for: metric, total: 100, at: 1)
        #expect(tracker.rate(for: metric, total: 300, at: 3) == 100)
    }

    /// A counter that goes backwards means a wrap or a replaced device. Both
    /// would produce a huge negative rate and a spike on the chart.
    @Test("skips the interval when a counter goes backwards")
    func wrapped() {
        var tracker = RateTracker()
        let metric = MetricID("c")
        _ = tracker.rate(for: metric, total: 500, at: 1)
        #expect(tracker.rate(for: metric, total: 10, at: 2) == nil)
        // The next interval works again, measured from the new baseline.
        #expect(tracker.rate(for: metric, total: 20, at: 3) == 10)
    }
}
