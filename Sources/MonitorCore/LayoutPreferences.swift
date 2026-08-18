import Foundation

/// What the panel draws when nobody has said otherwise.
///
/// These lists were hard-coded in the dashboard before the layout could be
/// chosen, and they were the panel's order until it could be dragged.
///
/// They are now the **seed** for that order, not the order itself:
/// `PanelArrangement` holds where every tile actually sits, and reads these
/// once to decide where a tile it has never seen belongs. Order still matters
/// as much as membership — a dial that moves between launches is one you have
/// to hunt for — which is why a metric switched on lands at a considered
/// position rather than wherever the registry happened to yield it, and why a
/// sensor that appears when you plug in a dock lands among its own kind rather
/// than at the end.
///
/// Read these to answer "where does this go if nobody has said"; read
/// `PanelArrangement` to answer "where is this".
public enum LayoutDefaults {
    /// The dials on the wall, left to right.
    ///
    /// Rates only. A gauge answers "how hard is this working right now against
    /// what it can do", which is the question for disk and network throughput
    /// and not the question for memory.
    public static let gaugeOrder: [MetricID] = [
        MetricID("disk.bytes.read"),
        MetricID("disk.bytes.written"),
        MetricID("net.bits.in"),
        MetricID("net.bits.out"),
    ]

    /// Chart cards above the section rule, in the order they appear.
    ///
    /// Disk and network are here as well as on the gauge wall on purpose: a
    /// needle cannot tell you a transfer has been running for a minute.
    public static let performanceGroupOrder = [
        "CPU", "CPU Cores", "Memory", "Disk", "Network", "GPU", "Disk Latency",
    ]

    /// Chart cards below the rule: what the machine is doing to itself — heat,
    /// fans, watts. Every one of these is missing on some Mac, so the section
    /// draws only what this machine reports.
    public static let sensorGroupOrder = ["Temperature", "Fans", "Power"]

    /// Groups left off both lists by default: "Disk Ops", "Network Packets"
    /// and "Memory Paging" are diagnostic detail rather than something to
    /// glance at. They are one checkbox away rather than gone.
    public static func showsChart(_ descriptor: MetricDescriptor) -> Bool {
        performanceGroupOrder.contains(descriptor.group)
            || sensorGroupOrder.contains(descriptor.group)
    }

    public static func showsGauge(_ descriptor: MetricDescriptor) -> Bool {
        gaugeOrder.contains(descriptor.id)
    }
}

/// Which metrics get a dial, and which get a line on a chart.
///
/// The two are independent, and both are per metric. A dial is per metric
/// because it shows one number. A chart is per metric but drawn per *group*:
/// every charted metric in a group shares that group's card, so ticking
/// Network In and Network Out gives one Network chart with two lines, not two
/// charts. That is the point of the group — in and out are only readable
/// against each other.
///
/// A value type in `MonitorCore` rather than a view model, so the merge rules
/// below are testable without a window.
public struct LayoutPreferences: Codable, Equatable, Sendable {
    /// Raw metric ids rather than `MetricID`, because this is what gets
    /// written to preferences and a bare list of strings is the shape that
    /// survives a change to the type.
    private var gauges: Set<String>
    private var charts: Set<String>
    /// Every metric this set has already decided about.
    ///
    /// Without it a metric added by a later version — or by a machine that
    /// starts reporting a sensor it did not before — would be silently off,
    /// because "not in `charts`" and "never heard of" look the same. Tracking
    /// what is known separates them, so a new metric gets its default and
    /// everything else keeps whatever was chosen.
    private var known: Set<String>

    public init(
        gauges: Set<MetricID> = [], charts: Set<MetricID> = [], known: Set<MetricID> = []
    ) {
        self.gauges = Set(gauges.map(\.rawValue))
        self.charts = Set(charts.map(\.rawValue))
        self.known = Set(known.map(\.rawValue)).union(self.gauges).union(self.charts)
    }

    public func showsGauge(_ metric: MetricID) -> Bool { gauges.contains(metric.rawValue) }
    public func showsChart(_ metric: MetricID) -> Bool { charts.contains(metric.rawValue) }

    public mutating func setGauge(_ shown: Bool, for metric: MetricID) {
        known.insert(metric.rawValue)
        if shown { gauges.insert(metric.rawValue) } else { gauges.remove(metric.rawValue) }
    }

    public mutating func setChart(_ shown: Bool, for metric: MetricID) {
        known.insert(metric.rawValue)
        if shown { charts.insert(metric.rawValue) } else { charts.remove(metric.rawValue) }
    }

    /// The panel as it shipped: `LayoutDefaults` applied to every descriptor.
    public static func defaults(for descriptors: [MetricDescriptor]) -> LayoutPreferences {
        LayoutPreferences(
            gauges: Set(descriptors.filter(LayoutDefaults.showsGauge).map(\.id)),
            charts: Set(descriptors.filter(LayoutDefaults.showsChart).map(\.id)),
            known: Set(descriptors.map(\.id))
        )
    }

    /// Gives any metric this set has not seen before its default state, and
    /// leaves every choice already made alone.
    public func adoptingDefaults(for descriptors: [MetricDescriptor]) -> LayoutPreferences {
        var merged = self
        for descriptor in descriptors where !known.contains(descriptor.id.rawValue) {
            merged.setGauge(LayoutDefaults.showsGauge(descriptor), for: descriptor.id)
            merged.setChart(LayoutDefaults.showsChart(descriptor), for: descriptor.id)
        }
        return merged
    }
}
