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

    /// Which metrics get a dial and which get a line, as chosen in the
    /// preferences window. Written back on every change: a preferences pane
    /// that forgets is not a preferences pane.
    public var layout: LayoutPreferences {
        didSet {
            guard layout != oldValue else { return }
            LayoutPreferencesStore.save(layout)
        }
    }

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
        layout = LayoutPreferencesStore.load(for: all)

        // A scale for every metric, not only the ones a dial shows today. Any
        // metric can be given a dial in preferences, and auto-ranging needs
        // history: a scale built the moment its checkbox is ticked would start
        // from the floor and climb, so the first reading on a new dial would
        // be pinned at full deflection.
        for descriptor in all {
            scales[descriptor.id] = Self.makeScale(descriptor)
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

    // MARK: - What the panel draws

    /// The dials on the wall, left to right.
    ///
    /// `LayoutDefaults.gaugeOrder` first, so the four the app opens with never
    /// move, then anything else that has been ticked, by metric id. Both halves
    /// are fixed orders rather than registry order for the same reason: a dial
    /// that moves between launches is a dial you stop glancing at.
    public var gaugeMetrics: [MetricID] {
        let ordered = LayoutDefaults.gaugeOrder.filter {
            descriptors[$0] != nil && layout.showsGauge($0)
        }
        let rest = descriptors.keys
            .filter { layout.showsGauge($0) && !LayoutDefaults.gaugeOrder.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
        return ordered + rest
    }

    /// Every group this machine reports, in the order the panel lays its cards
    /// out — which is the order the preferences list has to use as well, or the
    /// list and the window it configures disagree about where things are.
    public var groupOrder: [(name: String, metrics: [MetricID])] {
        let byName = Dictionary(
            groups().map { ($0.name, $0.metrics) }, uniquingKeysWith: { first, _ in first }
        )
        let order = LayoutDefaults.performanceGroupOrder + extraGroupNames
            + LayoutDefaults.sensorGroupOrder
        return order.compactMap { name in
            byName[name].map { (name: name, metrics: $0) }
        }
    }

    /// Groups nothing draws by default — "Disk Ops", "Network Packets",
    /// "Memory Paging". They have to land somewhere once they are ticked, and
    /// performance is what they are, so they go after the named performance
    /// cards and before the section rule.
    private var extraGroupNames: [String] {
        let named = Set(
            LayoutDefaults.performanceGroupOrder + LayoutDefaults.sensorGroupOrder
        )
        return groups().map(\.name).filter { !named.contains($0) }
    }

    /// Chart cards above the section rule.
    public var performanceGroups: [(name: String, metrics: [MetricID])] {
        chartGroups(in: LayoutDefaults.performanceGroupOrder + extraGroupNames)
    }

    /// Chart cards below the rule: temperature, fans, power.
    public var sensorGroups: [(name: String, metrics: [MetricID])] {
        chartGroups(in: LayoutDefaults.sensorGroupOrder)
    }

    /// Groups with at least one charted metric, in registry order. A group
    /// whose metrics are all unticked has no card at all rather than an empty
    /// one.
    private var chartGroups: [(name: String, metrics: [MetricID])] {
        groups().compactMap { group in
            let metrics = group.metrics.filter(layout.showsChart)
            return metrics.isEmpty ? nil : (name: group.name, metrics: metrics)
        }
    }

    private func chartGroups(in order: [String]) -> [(name: String, metrics: [MetricID])] {
        let available = Dictionary(
            chartGroups.map { ($0.name, $0.metrics) }, uniquingKeysWith: { first, _ in first }
        )
        return order.compactMap { name in
            guard let metrics = available[name] else { return nil }
            return (name: name, metrics: metrics)
        }
    }

    /// The two things preferences can turn on for a metric.
    public enum LayoutColumn: String, CaseIterable, Sendable {
        case gauge, chart
    }

    /// A checkbox's worth of the layout, as a binding.
    ///
    /// Vended by the model rather than built in the view because a metric's row
    /// and its section heading both write the same state, and a single
    /// definition is what keeps them from drifting.
    public func binding(_ column: LayoutColumn, for metric: MetricID) -> Binding<Bool> {
        switch column {
        case .gauge:
            Binding(
                get: { self.layout.showsGauge(metric) },
                set: { self.layout.setGauge($0, for: metric) }
            )
        case .chart:
            Binding(
                get: { self.layout.showsChart(metric) },
                set: { self.layout.setChart($0, for: metric) }
            )
        }
    }

    /// Puts every metric back to the layout the app ships with.
    public func restoreDefaultLayout() {
        layout = LayoutPreferences.defaults(for: Array(descriptors.values))
    }

    // MARK: - Gauge policy

    /// A sensible smallest full scale per unit, so an idle gauge does not sit
    /// pinned at the top of a dial reading 200 bytes a second.
    ///
    /// Throughput starts at ten mega-somethings: 0–10 MB/s and 0–10 Mbit/s.
    /// Those are the scales an idle machine spends nearly all its time on, so
    /// they are the ones worth being able to read without checking.
    static func gaugeFloor(_ descriptor: MetricDescriptor) -> Double {
        switch descriptor.unit {
        case .bytesPerSecond, .bitsPerSecond: 10_000_000
        case .operationsPerSecond: 100
        default: 1
        }
    }

    /// How long a throughput dial holds a scale it was pushed up to.
    ///
    /// Ten minutes is long by the standards of the 15-second decay the other
    /// gauges use, and deliberately so: the point of the high-water mark is
    /// that a transfer you were watching does not erase its own evidence the
    /// moment it finishes.
    static let throughputDecay: TimeInterval = 600

    /// Throughput dials climb decades and hold a high-water mark; everything
    /// else keeps the 1-2-5 ladder and the short decay.
    ///
    /// The split is about whether the reader has the ladder in their head.
    /// MB/s and Mbit/s come in tens, hundreds and thousands and are quoted that
    /// way, so a decade dial is predictable enough to read from needle position
    /// alone. Operations per second have no such convention, and pinning them
    /// to decades would waste most of the sweep.
    static func makeScale(_ descriptor: MetricDescriptor) -> GaugeScale {
        switch descriptor.unit {
        case .bytesPerSecond, .bitsPerSecond:
            GaugeScale(
                floor: gaugeFloor(descriptor),
                decayInterval: throughputDecay,
                ladder: .decade
            )
        default:
            GaugeScale(floor: gaugeFloor(descriptor))
        }
    }
}
