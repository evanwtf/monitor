import Foundation

/// One resizable dimension of the panel: how small, how large, and where it
/// starts.
///
/// A struct rather than three loose constants because the three always travel
/// together — a slider needs all of them, and a stored size is only meaningful
/// against the bounds it was clamped to.
public struct SizeRange: Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let initial: Double

    public init(minimum: Double, maximum: Double, initial: Double) {
        self.minimum = minimum
        self.maximum = maximum
        self.initial = initial
    }

    public func clamp(_ value: Double) -> Double {
        // A NaN read back from a corrupt preference compares false against both
        // bounds and would survive `min`/`max` untouched, then propagate into
        // the grid's column width. Send it to the starting size instead.
        guard value.isFinite else { return initial }
        return Swift.min(Swift.max(minimum, value), maximum)
    }

    public var bounds: ClosedRange<Double> { minimum...maximum }
}

/// How big the three resizable things are allowed to get.
///
/// These live in `MonitorCore` rather than in `Theme.Layout` because they are
/// now part of the stored model: `PanelArrangement` clamps to them when it
/// loads, and a stored size has to be checked against bounds the value type can
/// see. `Theme.Layout` forwards to them, so the views still read one place.
public enum PanelSize {
    /// Dials are square, so this is their height too. The floor is where the
    /// readout stops being legible; the ceiling is a sanity limit, and on a
    /// window narrower than one row of ceiling-sized dials the real limit is
    /// the width, which only the view can know.
    public static let gauge = SizeRange(minimum: 90, maximum: 360, initial: 130)
    /// Minimum card width, which is really a column count in disguise: 260
    /// gives four columns at 1180pt and three at 900.
    public static let chartWidth = SizeRange(minimum: 200, maximum: 600, initial: 260)
    /// The plot area alone, not counting the card's header and padding. Still a
    /// *minimum*, so a shorter window scrolls rather than squeezing.
    public static let chartHeight = SizeRange(minimum: 100, maximum: 400, initial: 125)
}

/// Where every tile sits, and how big the tiles are.
///
/// The panel's order used to be *derived*: the dashboard recomputed it from the
/// constants in `LayoutDefaults` on every access. Once a dial can be dragged,
/// order is data, and this is where it lives.
///
/// Note what this is not. `LayoutPreferences` says **what is drawn**; this says
/// **where it goes and how big it is**. Two structs and two preference keys, so
/// a corrupt arrangement costs a layout rather than every checkbox somebody
/// ticked.
///
/// A value type in `MonitorCore` so the merge and move rules are testable
/// without a window to drag things around in.
public struct PanelArrangement: Codable, Equatable, Sendable {
    /// Which side of the rule a chart card sits on.
    ///
    /// The split is a starting position, not a rule about what belongs where:
    /// a card can be dragged across, because the pairing somebody cares about
    /// may well be CPU load beside CPU temperature.
    public enum ChartSection: String, Codable, CaseIterable, Sendable {
        case performance, sensors
    }

    /// Raw strings rather than `MetricID`, for the same reason
    /// `LayoutPreferences` uses them: this is what gets written to preferences,
    /// and a bare list of strings is the shape that survives a change to the
    /// type.
    private var gauges: [String]
    private var performance: [String]
    private var sensors: [String]

    private var gaugeSizeValue: Double
    private var chartWidthValue: Double
    private var chartHeightValue: Double

    /// Clamped on the way in, so no caller can store a size the panel cannot
    /// draw — including a decoder reading a value somebody edited by hand.
    public var gaugeSize: Double {
        get { gaugeSizeValue }
        set { gaugeSizeValue = PanelSize.gauge.clamp(newValue) }
    }

    public var chartWidth: Double {
        get { chartWidthValue }
        set { chartWidthValue = PanelSize.chartWidth.clamp(newValue) }
    }

    public var chartHeight: Double {
        get { chartHeightValue }
        set { chartHeightValue = PanelSize.chartHeight.clamp(newValue) }
    }

    /// Spelled out so the stored JSON carries the public names rather than the
    /// backing properties, and so `init(from:)` below can be written by hand.
    private enum CodingKeys: String, CodingKey {
        case gauges, performance, sensors
        case gaugeSizeValue = "gaugeSize"
        case chartWidthValue = "chartWidth"
        case chartHeightValue = "chartHeight"
    }

    /// Written out rather than synthesised because a synthesised one assigns
    /// straight to the stored properties and skips the clamping setters — so a
    /// preference edited by hand, or written by a version with different
    /// bounds, would come back as a column width the grid cannot draw.
    ///
    /// Every field is optional on the way in: a stored arrangement from a
    /// version that did not have one should adopt its default, not fail to
    /// decode and take the whole layout with it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            gauges: (container.decodeIfPresent([String].self, forKey: .gauges) ?? [])
                .map { MetricID($0) },
            performance: container.decodeIfPresent(
                [String].self, forKey: .performance
            ) ?? [],
            sensors: container.decodeIfPresent([String].self, forKey: .sensors) ?? [],
            gaugeSize: container.decodeIfPresent(Double.self, forKey: .gaugeSizeValue)
                ?? PanelSize.gauge.initial,
            chartWidth: container.decodeIfPresent(Double.self, forKey: .chartWidthValue)
                ?? PanelSize.chartWidth.initial,
            chartHeight: container.decodeIfPresent(Double.self, forKey: .chartHeightValue)
                ?? PanelSize.chartHeight.initial
        )
    }

    public init(
        gauges: [MetricID] = [],
        performance: [String] = [],
        sensors: [String] = [],
        gaugeSize: Double = PanelSize.gauge.initial,
        chartWidth: Double = PanelSize.chartWidth.initial,
        chartHeight: Double = PanelSize.chartHeight.initial
    ) {
        self.gauges = gauges.map(\.rawValue)
        // A group named in both lists would draw two cards for one group, so
        // the first mention wins and the duplicate is dropped.
        let above = performance.uniqued()
        self.performance = above
        self.sensors = sensors.uniqued().filter { !above.contains($0) }
        gaugeSizeValue = PanelSize.gauge.clamp(gaugeSize)
        chartWidthValue = PanelSize.chartWidth.clamp(chartWidth)
        chartHeightValue = PanelSize.chartHeight.clamp(chartHeight)
    }

    // MARK: - Reading

    /// Every metric that has a place on the wall, left to right.
    ///
    /// This is a position, not a decision to draw: whether a dial appears is
    /// `LayoutPreferences.showsGauge`. Keeping a position for a metric that is
    /// switched off is the point — turn it back on and it returns to where it
    /// was rather than to the end of the row.
    public var gaugeOrder: [MetricID] { gauges.map { MetricID($0) } }

    public func groupOrder(in section: ChartSection) -> [String] {
        switch section {
        case .performance: performance
        case .sensors: sensors
        }
    }

    /// Which side of the rule a group is on, or nil if the arrangement has
    /// never heard of it.
    public func section(of group: String) -> ChartSection? {
        if performance.contains(group) { return .performance }
        if sensors.contains(group) { return .sensors }
        return nil
    }

    // MARK: - Moving

    /// Moves a dial to sit immediately before `other`, or to the end when
    /// `other` is nil.
    ///
    /// Insert-before rather than swap. For two adjacent dials the two are
    /// indistinguishable; for anything further apart swap flings an unrelated
    /// dial across the wall to the space you just left, which is not what
    /// dragging something looks like anywhere else.
    ///
    /// Stated in terms of the neighbour rather than an index on purpose: the
    /// caller has a drop target, not a number, and computing the number means
    /// remembering that removing the dragged item shifts everything after it.
    public mutating func moveGauge(_ metric: MetricID, before other: MetricID?) {
        gauges = Self.move(metric.rawValue, before: other?.rawValue, in: gauges)
    }

    /// Moves a chart card within its section, or across the rule into another
    /// one. `other` nil puts it at the end of the destination section.
    public mutating func moveGroup(
        _ group: String, to section: ChartSection, before other: String? = nil
    ) {
        performance.removeAll { $0 == group }
        sensors.removeAll { $0 == group }
        switch section {
        case .performance: performance = Self.insert(group, before: other, in: performance)
        case .sensors: sensors = Self.insert(group, before: other, in: sensors)
        }
    }

    /// Removing first and inserting second is what makes the neighbour form
    /// safe: by the time the index is looked up, the list no longer contains
    /// the thing being moved.
    private static func move(_ item: String, before other: String?,
                             in list: [String]) -> [String]
    {
        // Dropping something onto itself is a gesture that ended where it
        // started, not a request to move it to the end.
        guard item != other else { return list }
        var moved = list
        moved.removeAll { $0 == item }
        return insert(item, before: other, in: moved)
    }

    private static func insert(
        _ item: String, before other: String?, in list: [String]
    ) -> [String] {
        var inserted = list
        if let other, let index = inserted.firstIndex(of: other) {
            inserted.insert(item, at: index)
        } else {
            // No neighbour, or a neighbour that is not in this list: the end is
            // the only position that is certainly valid.
            inserted.append(item)
        }
        return inserted
    }

    // MARK: - Defaults and merging

    /// The panel as it ships: `LayoutDefaults` order, with everything else
    /// slotted in behind it.
    public static func defaults(for descriptors: [MetricDescriptor]) -> PanelArrangement {
        PanelArrangement(
            gauges: defaultGaugeOrder(for: descriptors),
            performance: defaultGroups(.performance, for: descriptors),
            sensors: defaultGroups(.sensors, for: descriptors)
        )
    }

    /// Gives anything the arrangement has not seen a position, and moves
    /// nothing that already has one.
    ///
    /// `LayoutPreferences` needs a separate `known` set to do this, because in
    /// a set of what is switched on, "off" and "never heard of" are both
    /// absence. Order has no such ambiguity — **not being in the list is what
    /// unknown means** — so no extra bookkeeping is needed here.
    ///
    /// A new metric lands where it would have been rather than at the end: plug
    /// in a dock and its network card appears among the others, not below the
    /// sensors.
    ///
    /// Entries for metrics this machine no longer reports are left alone. They
    /// draw nothing, because the panel only draws what it has a descriptor for,
    /// and keeping them means an external GPU that comes back finds its old
    /// place still waiting.
    public func adoptingDefaults(for descriptors: [MetricDescriptor]) -> PanelArrangement {
        var merged = self
        merged.gauges = Self.merge(
            gauges, into: Self.defaultGaugeOrder(for: descriptors).map(\.rawValue)
        )
        // Groups merge against both lists at once. Checking only the
        // destination would put a group somebody dragged below the rule back
        // above it as well, and draw its card twice.
        let placed = Set(performance).union(sensors)
        for section in ChartSection.allCases {
            let wanted = Self.defaultGroups(section, for: descriptors)
                .filter { !placed.contains($0) }
            let existing = section == .performance ? performance : sensors
            let result = Self.merge(
                existing, into: Self.defaultGroups(section, for: descriptors),
                adding: Set(wanted)
            )
            switch section {
            case .performance: merged.performance = result
            case .sensors: merged.sensors = result
            }
        }
        return merged
    }

    /// Walks the default order and inserts anything missing after the last
    /// default item that *is* present, which is what "where it would have been"
    /// means when most of the list has been rearranged.
    ///
    /// `additions` limits what may be inserted; everything already placed
    /// elsewhere is excluded by the caller.
    private static func merge(
        _ current: [String], into defaults: [String], adding additions: Set<String>? = nil
    ) -> [String] {
        let present = Set(current)
        var merged = current
        // Where the last default item we have already seen sits in the result,
        // so a run of new items lands in its own order rather than reversed.
        var anchor = 0
        for item in defaults {
            if let index = merged.firstIndex(of: item) {
                // Never backwards. Once somebody has rearranged things, the
                // stored order and the default order disagree, and following
                // the default's idea of position would drag the anchor back up
                // the list — so the next new item lands before things that
                // should precede it.
                anchor = Swift.max(anchor, index + 1)
                continue
            }
            guard !present.contains(item) else { continue }
            guard additions?.contains(item) ?? true else { continue }
            merged.insert(item, at: Swift.min(anchor, merged.count))
            anchor += 1
        }
        return merged
    }

    /// Named dials first so the four the app opens with never move, then
    /// everything else by metric id. Every metric gets a position, not only the
    /// ones drawn today — see `gaugeOrder`.
    private static func defaultGaugeOrder(for descriptors: [MetricDescriptor]) -> [MetricID] {
        let known = Set(LayoutDefaults.gaugeOrder)
        let ids = Set(descriptors.map(\.id))
        let named = LayoutDefaults.gaugeOrder.filter(ids.contains)
        let rest = descriptors.map(\.id)
            .filter { !known.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
        return named + rest
    }

    /// A group's default side of the rule. Anything `LayoutDefaults` does not
    /// name — "Disk Ops", "Network Packets", "Memory Paging" — is performance,
    /// because that is what it is, and goes after the named cards.
    private static func defaultGroups(
        _ section: ChartSection, for descriptors: [MetricDescriptor]
    ) -> [String] {
        let available = descriptors.map(\.group).uniqued()
        switch section {
        case .performance:
            let named = Set(
                LayoutDefaults.performanceGroupOrder + LayoutDefaults.sensorGroupOrder
            )
            return LayoutDefaults.performanceGroupOrder.filter(available.contains)
                + available.filter { !named.contains($0) }.sorted()
        case .sensors:
            return LayoutDefaults.sensorGroupOrder.filter(available.contains)
        }
    }
}

extension [String] {
    /// First mention wins, order preserved. `Set` would lose the order, which
    /// is the only thing this type stores.
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
