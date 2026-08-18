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
            LayoutPreferencesStore.save(layout, to: defaults)
        }
    }

    /// Where every tile sits and how big the tiles are.
    ///
    /// Separate from `layout` because the two answer different questions: that
    /// one is what is drawn, this one is where it goes. Saved on every change
    /// like the layout is — but the *callers* decide when a change happens.
    /// A drag or a slider must call `commitArrangement` when the gesture ends
    /// rather than assign on every frame; see `PanelArrangementStore`.
    /// Deliberately without a `didSet` that saves, unlike `layout` beside it.
    ///
    /// A checkbox changes once when somebody clicks it, so saving on change is
    /// right there. A drag and a slider change continuously while the gesture
    /// is in flight, and the panel has to follow the pointer, so saving on
    /// change would turn one decision into a write per frame — the thing the
    /// endurance argument in `docs/storage.md` exists to prevent.
    ///
    /// So: mutate this freely during a gesture, and call `commitArrangement()`
    /// when it ends. A mutation never committed is lost at the next launch,
    /// which is the trade for not writing fifty times to move one dial.
    public var arrangement: PanelArrangement

    /// Where preferences are read and written.
    ///
    /// Injected rather than reached for, so a test can build a model without
    /// editing the preferences of whoever is running it. That is not a
    /// hypothetical: the first run of these tests turned on a gauge in the real
    /// panel and left it there.
    private let defaults: UserDefaults

    /// How often each kind of source is read.
    ///
    /// Half a second for counters rather than one: reading them costs well
    /// under a millisecond, and at 1 Hz the gauges visibly step — the needle
    /// animation can smooth the gap, but it cannot invent detail that was never
    /// sampled, so a short spike between ticks is simply missed.
    ///
    /// One second for sensors, because that is how often the SMC has anything
    /// new to say.
    public var sampling: SamplingPreferences = .default {
        didSet {
            guard sampling != oldValue else { return }
            SamplingPreferencesStore.save(sampling, to: defaults)
            Task { await sampler.setInterval(sampling.performance) }
        }
    }

    /// The master clock, which is also the counter sources' rate.
    public var interval: TimeInterval {
        get { sampling.performance }
        set { sampling.performance = newValue }
    }

    /// Ticks since the pump started, so a slow source can be read on every nth
    /// one. A counter rather than a deadline per source: it cannot drift, and
    /// every sample still lands on a master tick's timestamp.
    private var tickCount = 0

    /// How much live history to keep: ten minutes at two samples a second.
    public let historyCapacity = 1200

    public let descriptors: [MetricID: MetricDescriptor]
    private let sampler: Sampler
    private var pump: Task<Void, Never>?

    public init(
        sources: [any MetricSource] = SourceRegistry.makeAll(),
        defaults: UserDefaults = LayoutPreferencesStore.suite
    ) {
        self.defaults = defaults
        let all = sources.flatMap(\.descriptors)
        descriptors = Dictionary(
            all.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        metricsBySource = Dictionary(
            sources.map { ($0.id, Set($0.descriptors.map(\.id))) },
            uniquingKeysWith: { first, _ in first }
        )
        slowSources = sources
            .filter { $0.minimumInterval > 0 }
            .map { (id: $0.id, minimum: $0.minimumInterval) }

        let stored = SamplingPreferencesStore.load(from: defaults)
        sampling = stored
        sampler = Sampler(sources: sources, sinks: [], interval: stored.performance)
        layout = LayoutPreferencesStore.load(for: all, from: defaults)
        arrangement = PanelArrangementStore.load(for: all, from: defaults)

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
                let skipped = sourcesToSkipThisTick()
                let batch = await sampler.tick(skipping: skipped)
                ingest(batch, skipped: skipped)
                tickCount += 1
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
    }

    /// Metric ids per source, so a source skipped this tick can be excluded
    /// from the "produced nothing, must be broken" test below.
    private let metricsBySource: [String: Set<MetricID>]

    /// Sources that cannot produce a new value on every tick, with the floor
    /// the hardware imposes.
    private let slowSources: [(id: String, minimum: TimeInterval)]

    /// Which sources to leave alone on this tick.
    ///
    /// A slow source is read at whichever is longer: the floor its hardware
    /// imposes, or the interval asked for in preferences. Rounded to a whole
    /// number of master ticks, so its samples share timestamps with everything
    /// else instead of drifting against them.
    private func sourcesToSkipThisTick() -> Set<String> {
        var skipped: Set<String> = []
        for source in slowSources {
            let wanted = max(source.minimum, sampling.sensors)
            let divisor = max(1, Int((wanted / max(interval, 0.001)).rounded()))
            if tickCount % divisor != 0 { skipped.insert(source.id) }
        }
        return skipped
    }

    func ingest(_ batch: SampleBatch, skipped: Set<String> = []) {
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
        // source that failed or is not present on this machine — unless it was
        // simply not asked. A sensor read once a second must not grey its card
        // out on the ticks in between.
        let notAsked = skipped.reduce(into: Set<MetricID>()) { ids, source in
            ids.formUnion(metricsBySource[source] ?? [])
        }
        unavailable = Set(descriptors.keys)
            .subtracting(seen)
            .subtracting(warmingUp)
            .subtracting(notAsked)
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
    /// Order comes from the arrangement, membership from the layout: the
    /// arrangement holds a position for every metric, including the ones no
    /// dial is drawn for, so switching one on returns it to where it was rather
    /// than appending it to the end of the row.
    public var gaugeMetrics: [MetricID] {
        arrangement.gaugeOrder.filter {
            descriptors[$0] != nil && layout.showsGauge($0)
        }
    }

    /// Every group this machine reports, in the order the panel lays its cards
    /// out — which is the order the preferences list has to use as well, or the
    /// list and the window it configures disagree about where things are.
    ///
    /// So this reads the arrangement, exactly as the panel does. It was the
    /// `LayoutDefaults` constants before anything could be dragged, and leaving
    /// it that way is the way this breaks.
    public var groupOrder: [(name: String, metrics: [MetricID])] {
        let byName = Dictionary(
            groups().map { ($0.name, $0.metrics) }, uniquingKeysWith: { first, _ in first }
        )
        let order = arrangement.groupOrder(in: .performance)
            + arrangement.groupOrder(in: .sensors)
        return order.compactMap { name in
            byName[name].map { (name: name, metrics: $0) }
        }
    }

    /// Whether this machine reports anything that belongs below the rule.
    ///
    /// Asked of the *descriptors*, not of what the sensor section currently
    /// holds, so the answer does not change when somebody drags the last sensor
    /// card up into performance. A fanless, sensorless machine draws no section;
    /// every other machine keeps one, empty or not, as somewhere to drop a card
    /// back into.
    public var hasSensors: Bool {
        let sensors = Set(LayoutDefaults.sensorGroupOrder)
        return descriptors.values.contains { sensors.contains($0.group) }
    }

    /// Chart cards above the section rule.
    ///
    /// A group nothing draws by default — "Disk Ops", "Network Packets",
    /// "Memory Paging" — no longer needs special-casing into the gap before the
    /// rule: `PanelArrangement.adoptingDefaults` gave it a position when it
    /// first appeared, and this reads that.
    public var performanceGroups: [(name: String, metrics: [MetricID])] {
        chartGroups(in: arrangement.groupOrder(in: .performance))
    }

    /// Chart cards below the rule: temperature, fans, power by default, and
    /// whatever has been dragged down there since.
    public var sensorGroups: [(name: String, metrics: [MetricID])] {
        chartGroups(in: arrangement.groupOrder(in: .sensors))
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

    /// Puts every metric back to the layout the app ships with. Membership
    /// only: where things sit and how big they are is `restoreDefaultArrangement`,
    /// because "show me the default set of cards" and "put them back where they
    /// started" are two different regrets.
    public func restoreDefaultLayout() {
        layout = LayoutPreferences.defaults(for: Array(descriptors.values))
    }

    /// Puts every tile back where it started, at the size it started.
    public func restoreDefaultArrangement() {
        arrangement = PanelArrangement.defaults(for: Array(descriptors.values))
        commitArrangement()
    }

    /// Writes the arrangement out. Call this once, when a gesture ends.
    public func commitArrangement() {
        PanelArrangementStore.save(arrangement, to: defaults)
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
