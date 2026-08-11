import Foundation
import MonitorCore
import MonitorSources
import SwiftUI

/// The state behind the window.
///
/// v1 is realtime only: the model drives the sampler itself and keeps history
/// in memory. Nothing is written to disk and no daemon runs, so closing the
/// window loses the history — which is the limitation the persistent store and
/// the background sampler exist to remove later (`docs/roadmap.md`).
@MainActor
@Observable
public final class AppModel {
    /// Live history per metric, at the sampling rate.
    public private(set) var series: [MetricID: TimeSeries] = [:]
    /// Auto-ranging dial state, one per gauge metric.
    public private(set) var scales: [MetricID: GaugeScale] = [:]
    /// Sources that failed on the last tick, so the UI can grey out a card
    /// instead of drawing a flat line that looks like an idle machine.
    public private(set) var unavailable: Set<MetricID> = []

    /// Half a second by default rather than one. Reading every source costs
    /// well under a millisecond, and at 1 Hz the gauges visibly step: the
    /// needle animation can smooth the gap, but it cannot invent detail that
    /// was never sampled, so a short spike between ticks is simply missed.
    public var interval: TimeInterval = 0.5 {
        didSet { Task { await sampler.setInterval(interval) } }
    }

    /// How much live history to keep: ten minutes at two samples a second.
    public let historyCapacity = 1200

    public let descriptors: [MetricID: MetricDescriptor]
    private let sampler: Sampler
    private var pump: Task<Void, Never>?

    public init(sources: [any MetricSource] = SourceRegistry.makeAll()) {
        let all = sources.flatMap(\.descriptors)
        descriptors = Dictionary(
            all.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        sampler = Sampler(sources: sources, sinks: [], interval: 0.5)

        for descriptor in all where Self.isGauge(descriptor) {
            scales[descriptor.id] = GaugeScale(floor: Self.gaugeFloor(descriptor))
        }
    }

    public func start() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let batch = await sampler.tick()
                ingest(batch)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
    }

    func ingest(_ batch: SampleBatch) {
        var seen: Set<MetricID> = []
        for sample in batch.samples {
            seen.insert(sample.metric)
            series[sample.metric, default: TimeSeries(
                metric: sample.metric, capacity: historyCapacity
            )]
            .append(sample)
            scales[sample.metric]?.update(value: sample.value, at: sample.timestamp)
        }
        // A metric with a descriptor that produced no sample this tick is a
        // source that failed or is not present on this machine.
        unavailable = Set(descriptors.keys).subtracting(seen).subtracting(warmingUp)
    }

    /// Rate metrics have no value on the first tick by design, so they must not
    /// be reported as unavailable until they have had a chance to produce one.
    private var warmingUp: Set<MetricID> {
        series.isEmpty ? Set(descriptors.keys) : []
    }

    public func latest(_ metric: MetricID) -> Double {
        series[metric]?.latest?.value ?? 0
    }

    public func points(_ metric: MetricID) -> [Sample] {
        series[metric]?.points ?? []
    }

    public func descriptor(_ metric: MetricID) -> MetricDescriptor? {
        descriptors[metric]
    }

    /// Metric ids grouped by their descriptor's group, in a stable order.
    public func groups() -> [(name: String, metrics: [MetricID])] {
        let sorted = descriptors.values.sorted { $0.id.rawValue < $1.id.rawValue }
        var order: [String] = []
        var byGroup: [String: [MetricID]] = [:]
        for descriptor in sorted {
            if byGroup[descriptor.group] == nil { order.append(descriptor.group) }
            byGroup[descriptor.group, default: []].append(descriptor.id)
        }
        return order.map { (name: $0, metrics: byGroup[$0] ?? []) }
    }

    // MARK: - Gauge policy

    /// Rates get a dial; levels get a chart.
    ///
    /// A gauge shows "how fast, right now, against what this machine can do".
    /// That is the question for disk and network throughput. It is not the
    /// question for memory, where what matters is the trend over an hour, and a
    /// needle would just wobble.
    static func isGauge(_ descriptor: MetricDescriptor) -> Bool {
        switch descriptor.unit {
        case .bytesPerSecond, .operationsPerSecond: true
        default: false
        }
    }

    /// A sensible smallest full scale per unit, so an idle gauge does not sit
    /// pinned at the top of a dial reading 200 bytes a second.
    static func gaugeFloor(_ descriptor: MetricDescriptor) -> Double {
        switch descriptor.unit {
        case .bytesPerSecond: 10_000_000
        case .operationsPerSecond: 100
        default: 1
        }
    }
}
