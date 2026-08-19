import Foundation
import MonitorCore
@testable import MonitorUI
import Testing

/// A source that reports what it is told to, so the model can be driven without
/// a machine to read.
private final class StubSource: MetricSource, @unchecked Sendable {
    let id: String
    let descriptors: [MetricDescriptor]
    let minimumInterval: TimeInterval
    var value = 1.0

    init(id: String, group: String, names: [String], minimumInterval: TimeInterval = 0) {
        self.id = id
        self.minimumInterval = minimumInterval
        descriptors = names.map {
            MetricDescriptor(
                id: MetricID("\(id).\($0)"), name: $0, group: group, unit: .celsius
            )
        }
    }

    func read(at timestamp: TimeInterval) throws -> SampleBatch {
        SampleBatch(
            timestamp: timestamp,
            samples: descriptors
                .map { Sample(metric: $0.id, timestamp: timestamp, value: value) }
        )
    }
}

@MainActor
@Suite("AppModel")
struct AppModelTests {
    /// One throwaway defaults domain, wiped before each model is built.
    ///
    /// Two things this avoids. Without a domain of its own, each test reads and
    /// writes the preferences of whoever is running it — the first version of
    /// these tests turned on a gauge in the real panel and left it there, then
    /// leaked that state into the next test in the file. And a *fresh* domain
    /// per test would be worse in a quieter way: `suiteName` domains persist,
    /// so a uuid each time writes a new plist on every run, forever.
    private static let domain = "wtf.evan.monitor.tests"

    private static func makeModel() -> (AppModel, StubSource, StubSource) {
        let fast = StubSource(id: "disk", group: "Disk", names: ["Read"])
        let slow = StubSource(
            id: "sensors", group: "Temperature", names: ["CPU"], minimumInterval: 1
        )
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        return (AppModel(sources: [fast, slow], defaults: defaults), fast, slow)
    }

    /// One tick is one batch carrying every source's samples, which is what
    /// `Sampler.tick` returns. Ingesting them separately would look like two
    /// ticks that each lost a source.
    private static func batch(
        _ sources: [StubSource], at timestamp: TimeInterval
    ) -> SampleBatch {
        SampleBatch(
            timestamp: timestamp,
            samples: sources.flatMap { (try? $0.read(at: timestamp))?.samples ?? [] }
        )
    }

    /// The bug this guards against looks like a rendering glitch: a sensor read
    /// once a second produced no sample on the ticks in between, the model took
    /// that for a failed source, and the card greyed itself out twice a second.
    @Test("a source that was not asked is not reported unavailable")
    func skippedIsNotUnavailable() {
        let (model, fast, slow) = Self.makeModel()
        let now = Date().timeIntervalSince1970

        model.ingest(Self.batch([fast, slow], at: now), skipped: [])
        #expect(model.unavailable.isEmpty)

        // A tick that deliberately left the sensors alone.
        model.ingest(Self.batch([fast], at: now + 0.5), skipped: ["sensors"])
        #expect(model.unavailable.isEmpty)
    }

    /// The other half: a source that was asked and produced nothing is broken,
    /// and must still say so.
    @Test("a source that was asked and gave nothing is unavailable")
    func silentSourceIsUnavailable() {
        let (model, fast, slow) = Self.makeModel()
        let now = Date().timeIntervalSince1970

        model.ingest(Self.batch([fast, slow], at: now), skipped: [])
        #expect(model.unavailable.isEmpty)

        // Asked for, nothing came back.
        model.ingest(Self.batch([fast], at: now + 0.5), skipped: [])
        #expect(model.unavailable.contains(MetricID("sensors.CPU")))
    }

    @Test("the layout defaults leave the panel as it shipped")
    func defaultLayout() {
        let (model, _, _) = Self.makeModel()
        // Temperature is charted by default; a stub disk metric is not on any
        // of the named lists, so it lands in neither until it is ticked.
        #expect(model.layout.showsChart(MetricID("sensors.CPU")))
        #expect(model.sensorGroups.contains { $0.name == "Temperature" })
    }

    @Test("a group with nothing ticked draws no card")
    func emptyGroupHasNoCard() {
        let (model, _, _) = Self.makeModel()
        model.layout.setChart(false, for: MetricID("sensors.CPU"))
        #expect(!model.sensorGroups.contains { $0.name == "Temperature" })
    }

    @Test("enabling a gauge puts it on the wall")
    func gaugeOrder() {
        let (model, _, _) = Self.makeModel()
        #expect(model.gaugeMetrics.isEmpty)
        model.layout.setGauge(true, for: MetricID("sensors.CPU"))
        #expect(model.gaugeMetrics == [MetricID("sensors.CPU")])
    }

    // MARK: - The arrangement

    @Test("the panel draws dials in the arrangement's order, not the registry's")
    func gaugesFollowTheArrangement() {
        let (model, _, _) = Self.makeModel()
        model.layout.setGauge(true, for: MetricID("sensors.CPU"))
        model.layout.setGauge(true, for: MetricID("disk.Read"))
        let first = model.gaugeMetrics
        #expect(first.count == 2)

        model.arrangement.moveGauge(first[1], before: first[0])
        #expect(model.gaugeMetrics == [first[1], first[0]])
    }

    @Test("a card dragged across the rule draws in the other section")
    func cardsFollowTheArrangement() {
        let (model, _, _) = Self.makeModel()
        #expect(model.sensorGroups.contains { $0.name == "Temperature" })

        model.arrangement.moveGroup("Temperature", to: .performance)
        #expect(model.performanceGroups.contains { $0.name == "Temperature" })
        #expect(model.sensorGroups.isEmpty)
    }

    /// The comment on `groupOrder` has said this since before anything could be
    /// dragged: the preferences list and the window it configures have to agree
    /// about where things are. Reordering the panel while the Layout tab kept
    /// `LayoutDefaults` order is the way that breaks.
    @Test("the preferences list follows the panel's order")
    func preferencesListFollowsThePanel() {
        let (model, _, _) = Self.makeModel()
        model.arrangement.moveGroup("Temperature", to: .performance, before: "Disk")
        let listed = model.groupOrder.map(\.name)
        let panel = (model.performanceGroups + model.sensorGroups).map(\.name)
        #expect(listed == panel)
        #expect(listed.first == "Temperature")
    }

    @Test("membership is still the layout, position is the arrangement")
    func arrangementDoesNotDraw() {
        let (model, _, _) = Self.makeModel()
        // Every metric has a position, including the ones no dial is drawn for.
        #expect(model.arrangement.gaugeOrder.contains(MetricID("sensors.CPU")))
        #expect(model.gaugeMetrics.isEmpty)
    }

    /// A dial switched off keeps its place, so switching it back on returns it
    /// to where it was rather than appending it to the end of the row.
    @Test("a dial switched off and on again comes back to the same place")
    func positionSurvivesBeingSwitchedOff() {
        let (model, _, _) = Self.makeModel()
        model.layout.setGauge(true, for: MetricID("sensors.CPU"))
        model.layout.setGauge(true, for: MetricID("disk.Read"))
        model.arrangement.moveGauge(MetricID("sensors.CPU"), before: MetricID("disk.Read"))

        model.layout.setGauge(false, for: MetricID("sensors.CPU"))
        #expect(model.gaugeMetrics == [MetricID("disk.Read")])
        model.layout.setGauge(true, for: MetricID("sensors.CPU"))
        #expect(model.gaugeMetrics == [MetricID("sensors.CPU"), MetricID("disk.Read")])
    }

    // MARK: - Persistence

    @Test("a committed arrangement survives a relaunch")
    func arrangementPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.domain))
        defaults.removePersistentDomain(forName: Self.domain)
        let sources = [
            StubSource(id: "disk", group: "Disk", names: ["Read"]),
            StubSource(id: "sensors", group: "Temperature", names: ["CPU"]),
        ]

        let first = AppModel(sources: sources, defaults: defaults)
        first.arrangement.moveGroup("Temperature", to: .performance, before: "Disk")
        first.commitArrangement()

        let second = AppModel(sources: sources, defaults: defaults)
        #expect(second.arrangement.section(of: "Temperature") == .performance)
        #expect(second.performanceGroups.map(\.name) == ["Temperature", "Disk"])
    }

    /// The whole reason `arrangement` has no saving `didSet`: a drag mutates it
    /// on every frame, and every one of those must not reach `UserDefaults`.
    @Test("an uncommitted change is not written")
    func uncommittedChangeIsNotWritten() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.domain))
        defaults.removePersistentDomain(forName: Self.domain)
        let sources = [StubSource(id: "disk", group: "Disk", names: ["Read"])]

        let first = AppModel(sources: sources, defaults: defaults)
        first.arrangement.gaugeSize = 300
        #expect(first.arrangement.gaugeSize == 300)

        let second = AppModel(sources: sources, defaults: defaults)
        #expect(second.arrangement.gaugeSize == PanelSize.gauge.initial)
    }

    /// Unlike the arrangement, this one saves on change: it is a checkbox, so
    /// there is no gesture to end.
    @Test("the chart setting is written the moment it changes")
    func chartPreferencesPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.domain))
        defaults.removePersistentDomain(forName: Self.domain)
        let sources = [StubSource(id: "disk", group: "Disk", names: ["Read"])]

        let first = AppModel(sources: sources, defaults: defaults)
        #expect(first.charts.mirrorsPairs == false)
        first.charts.mirrorsPairs = true

        let second = AppModel(sources: sources, defaults: defaults)
        #expect(second.charts.mirrorsPairs)
    }

    @Test("restoring the arrangement puts everything back and writes it")
    func restoreArrangement() throws {
        let defaults = try #require(UserDefaults(suiteName: Self.domain))
        defaults.removePersistentDomain(forName: Self.domain)
        let sources = [
            StubSource(id: "disk", group: "Disk", names: ["Read"]),
            StubSource(id: "sensors", group: "Temperature", names: ["CPU"]),
        ]

        let first = AppModel(sources: sources, defaults: defaults)
        first.arrangement.moveGroup("Temperature", to: .performance)
        first.arrangement.gaugeSize = 300
        first.commitArrangement()
        first.restoreDefaultArrangement()

        let second = AppModel(sources: sources, defaults: defaults)
        #expect(second.arrangement.section(of: "Temperature") == .sensors)
        #expect(second.arrangement.gaugeSize == PanelSize.gauge.initial)
    }
}

/// The neighbour arithmetic behind a drop.
///
/// A drop lands on *half* a tile: the leading half means "before this one", the
/// trailing half means "before whatever comes next". Getting the second one
/// wrong is the classic reorder bug — every rightward drag lands one place short
/// — and it is invisible in a screenshot, so it is pinned here.
@Suite("Drop neighbours")
struct DropNeighbourTests {
    private func neighbour(
        after target: String, in order: [String], edge: DropTarget.Edge
    ) -> String? {
        DashboardView.neighbour(after: target, in: order, edge: edge)
    }

    @Test("the leading half means before the tile itself")
    func leadingEdge() {
        #expect(neighbour(after: "b", in: ["a", "b", "c"], edge: .leading) == "b")
    }

    @Test("the trailing half means before whatever follows")
    func trailingEdge() {
        #expect(neighbour(after: "b", in: ["a", "b", "c"], edge: .trailing) == "c")
    }

    /// Nothing follows the last tile, and nil is what the model reads as "the
    /// end". Without this the last position on a row is unreachable.
    @Test("the trailing half of the last tile means the end")
    func trailingEdgeOfLast() {
        #expect(neighbour(after: "c", in: ["a", "b", "c"], edge: .trailing) == nil)
    }

    @Test("a tile that is not in the list drops at the end rather than nowhere")
    func unknownTarget() {
        #expect(neighbour(after: "z", in: ["a", "b"], edge: .trailing) == nil)
    }
}
