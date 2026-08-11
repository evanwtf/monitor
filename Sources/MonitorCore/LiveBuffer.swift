import Foundation

/// The most recent samples, in memory, for the live charts.
///
/// In v1 this is the *only* place history lives. Nothing is written to disk, so
/// the window of history is exactly `capacity` samples and it dies with the
/// process. That is a real limitation and it is a deliberate one — see
/// `docs/storage.md`.
public actor LiveBuffer: SampleSink {
    private var series: [MetricID: TimeSeries] = [:]
    private let capacity: Int

    /// Ten minutes at one sample a second.
    public init(capacity: Int = 600) {
        self.capacity = capacity
    }

    public func receive(_ batch: SampleBatch) async {
        for sample in batch.samples {
            series[
                sample.metric,
                default: TimeSeries(metric: sample.metric, capacity: capacity)
            ]
            .append(sample)
        }
    }

    public func points(for metric: MetricID) -> [Sample] {
        series[metric]?.points ?? []
    }

    public func latest(for metric: MetricID) -> Sample? {
        series[metric]?.latest
    }

    public var metrics: [MetricID] { Array(series.keys) }
}
