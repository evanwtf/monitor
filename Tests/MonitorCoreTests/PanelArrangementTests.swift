import Foundation
@testable import MonitorCore
import Testing

@Suite("PanelArrangement")
struct PanelArrangementTests {
    /// A stand-in machine: two disk rates, one network rate, one sensor.
    static func descriptors() -> [MetricDescriptor] {
        [
            MetricDescriptor(
                id: MetricID("disk.bytes.read"), name: "Read", group: "Disk",
                unit: .bytesPerSecond
            ),
            MetricDescriptor(
                id: MetricID("disk.bytes.written"), name: "Write", group: "Disk",
                unit: .bytesPerSecond
            ),
            MetricDescriptor(
                id: MetricID("net.bits.in"), name: "In", group: "Network",
                unit: .bitsPerSecond
            ),
            MetricDescriptor(
                id: MetricID("cpu.total"), name: "Total", group: "CPU", unit: .fraction
            ),
            MetricDescriptor(
                id: MetricID("sensors.CPU"), name: "CPU", group: "Temperature",
                unit: .celsius
            ),
        ]
    }

    // MARK: - Defaults

    @Test("Dials the app opens with keep their order, and everything else follows")
    func defaultGaugeOrder() {
        let arrangement = PanelArrangement.defaults(for: Self.descriptors())
        let order = arrangement.gaugeOrder
        // The named four first, in LayoutDefaults order, minus the one this
        // machine does not report.
        #expect(order.prefix(3) == [
            MetricID("disk.bytes.read"),
            MetricID("disk.bytes.written"),
            MetricID("net.bits.in"),
        ])
        // Every metric gets a position, not only the ones drawn by default.
        #expect(Set(order) == Set(Self.descriptors().map(\.id)))
    }

    @Test("Groups start on the side of the rule LayoutDefaults puts them")
    func defaultSections() {
        let arrangement = PanelArrangement.defaults(for: Self.descriptors())
        #expect(arrangement.groupOrder(in: .performance) == ["CPU", "Disk", "Network"])
        #expect(arrangement.groupOrder(in: .sensors) == ["Temperature"])
    }

    @Test("A group LayoutDefaults does not name lands after the named performance cards")
    func unnamedGroupIsPerformance() {
        var descriptors = Self.descriptors()
        descriptors.append(
            MetricDescriptor(
                id: MetricID("disk.ops.read"), name: "Reads", group: "Disk Ops",
                unit: .operationsPerSecond
            )
        )
        let arrangement = PanelArrangement.defaults(for: descriptors)
        let performance = arrangement.groupOrder(in: .performance)
        #expect(performance.last == "Disk Ops")
        #expect(arrangement.section(of: "Disk Ops") == .performance)
    }

    // MARK: - Moving

    @Test("A dial moves to sit before its drop target")
    func moveGaugeBefore() {
        var arrangement = PanelArrangement.defaults(for: Self.descriptors())
        arrangement.moveGauge(MetricID("net.bits.in"), before: MetricID("disk.bytes.read"))
        #expect(arrangement.gaugeOrder.prefix(2) == [
            MetricID("net.bits.in"), MetricID("disk.bytes.read"),
        ])
    }

    /// The bug the neighbour-based API exists to prevent: with indices, removing
    /// the dragged item shifts every position after it, so moving something
    /// rightwards lands one place short.
    @Test("Moving a dial rightwards lands where the target was, not one short")
    func moveGaugeRightwards() {
        var arrangement = PanelArrangement(
            gauges: [MetricID("a"), MetricID("b"), MetricID("c"), MetricID("d")]
        )
        arrangement.moveGauge(MetricID("a"), before: MetricID("d"))
        #expect(arrangement.gaugeOrder.map(\.rawValue) == ["b", "c", "a", "d"])
    }

    @Test("A dial dropped past the end goes to the end")
    func moveGaugeToEnd() {
        var arrangement = PanelArrangement(
            gauges: [MetricID("a"), MetricID("b"), MetricID("c")]
        )
        arrangement.moveGauge(MetricID("a"), before: nil)
        #expect(arrangement.gaugeOrder.map(\.rawValue) == ["b", "c", "a"])
    }

    @Test("A dial dropped on itself does not move")
    func dropOnSelfIsNoMove() {
        let original = PanelArrangement(
            gauges: [MetricID("a"), MetricID("b"), MetricID("c")]
        )
        var arrangement = original
        arrangement.moveGauge(MetricID("b"), before: MetricID("b"))
        #expect(arrangement == original)
    }

    @Test("A dial dropped next to something not on the wall goes to the end, not nowhere")
    func unknownNeighbourAppends() {
        var arrangement = PanelArrangement(gauges: [MetricID("a"), MetricID("b")])
        arrangement.moveGauge(MetricID("a"), before: MetricID("nope"))
        #expect(arrangement.gaugeOrder.map(\.rawValue) == ["b", "a"])
    }

    @Test("A card dragged across the rule changes section and leaves the old one")
    func moveGroupAcrossTheRule() {
        var arrangement = PanelArrangement.defaults(for: Self.descriptors())
        arrangement.moveGroup("Temperature", to: .performance, before: "Disk")
        #expect(arrangement.groupOrder(in: .performance) == [
            "CPU", "Temperature", "Disk", "Network",
        ])
        #expect(arrangement.groupOrder(in: .sensors).isEmpty)
        #expect(arrangement.section(of: "Temperature") == .performance)
    }

    @Test("A card reordered within its section stays in it")
    func moveGroupWithinSection() {
        var arrangement = PanelArrangement.defaults(for: Self.descriptors())
        arrangement.moveGroup("Network", to: .performance, before: "CPU")
        #expect(arrangement.groupOrder(in: .performance) == ["Network", "CPU", "Disk"])
        #expect(arrangement.groupOrder(in: .sensors) == ["Temperature"])
    }

    // MARK: - Adopting defaults

    @Test("A metric the arrangement has never seen lands at its default position")
    func adoptsNewMetricAtDefaultPosition() {
        // Somebody's stored arrangement, from before this machine reported the
        // network. The two disk dials have been swapped, and that must survive.
        var stored = PanelArrangement(
            gauges: [MetricID("disk.bytes.written"), MetricID("disk.bytes.read")],
            performance: ["Disk", "CPU"],
            sensors: []
        )
        stored = stored.adoptingDefaults(for: Self.descriptors())
        let order = stored.gaugeOrder.map(\.rawValue)
        // The swap is untouched...
        #expect(order.prefix(2) == ["disk.bytes.written", "disk.bytes.read"])
        // ...and the newcomer is placed by the defaults, which put it after the
        // two disk dials rather than at the end of everything.
        #expect(order.firstIndex(of: "net.bits.in") == 2)
        #expect(stored.groupOrder(in: .performance) == ["Disk", "CPU", "Network"])
        #expect(stored.groupOrder(in: .sensors) == ["Temperature"])
    }

    @Test("A group moved across the rule is not put back by a later launch")
    func adoptingDoesNotUndoACrossSectionMove() {
        var stored = PanelArrangement.defaults(for: Self.descriptors())
        stored.moveGroup("Temperature", to: .performance, before: nil)
        let reloaded = stored.adoptingDefaults(for: Self.descriptors())
        #expect(reloaded.section(of: "Temperature") == .performance)
        #expect(reloaded.groupOrder(in: .sensors).isEmpty)
        // And exactly one card, not one on each side.
        let cards = reloaded.groupOrder(in: .performance).count { $0 == "Temperature" }
        #expect(cards == 1)
    }

    @Test("Several new metrics keep their default order rather than arriving reversed")
    func adoptsRunOfNewMetricsInOrder() throws {
        var stored = PanelArrangement(gauges: [MetricID("cpu.total")])
        stored = stored.adoptingDefaults(for: Self.descriptors())
        let order = stored.gaugeOrder.map(\.rawValue)
        let read = try #require(order.firstIndex(of: "disk.bytes.read"))
        let written = try #require(order.firstIndex(of: "disk.bytes.written"))
        let net = try #require(order.firstIndex(of: "net.bits.in"))
        #expect(read < written)
        #expect(written < net)
    }

    @Test("A metric this machine no longer reports is kept, not dropped")
    func staleEntriesSurvive() throws {
        var stored = PanelArrangement(gauges: [
            MetricID("gpu.utilization"),
            MetricID("cpu.total"),
        ])
        stored = stored.adoptingDefaults(for: Self.descriptors())
        let order = stored.gaugeOrder.map(\.rawValue)
        // Nothing draws it — the panel only draws what it has a descriptor for
        // — but plug the display back in and its position is still here.
        #expect(order.contains("gpu.utilization"))
        // Its position is kept relative to the other entries that were stored
        // with it. Where the *new* metrics land around it is not defined:
        // nothing in the defaults mentions a metric the defaults do not know,
        // so there is no answer to pin down.
        let gpu = try #require(order.firstIndex(of: "gpu.utilization"))
        let cpu = try #require(order.firstIndex(of: "cpu.total"))
        #expect(gpu < cpu)
    }

    @Test("Adopting twice changes nothing the second time")
    func adoptingIsIdempotent() {
        let once = PanelArrangement(gauges: [MetricID("cpu.total")])
            .adoptingDefaults(for: Self.descriptors())
        #expect(once.adoptingDefaults(for: Self.descriptors()) == once)
    }

    // MARK: - Sizes

    @Test("Sizes clamp to what the panel can draw")
    func sizesClamp() {
        var arrangement = PanelArrangement()
        arrangement.gaugeSize = 10000
        arrangement.chartWidth = 0
        arrangement.chartHeight = -5
        #expect(arrangement.gaugeSize == PanelSize.gauge.maximum)
        #expect(arrangement.chartWidth == PanelSize.chartWidth.minimum)
        #expect(arrangement.chartHeight == PanelSize.chartHeight.minimum)
    }

    @Test("A size that is not a number falls back to the starting size")
    func nonFiniteSizeFallsBack() {
        var arrangement = PanelArrangement()
        arrangement.gaugeSize = .nan
        #expect(arrangement.gaugeSize == PanelSize.gauge.initial)
    }

    @Test("An arrangement stored before a field existed still decodes")
    func decodingToleratesMissingFields() throws {
        let decoded = try JSONDecoder().decode(
            PanelArrangement.self, from: Data(#"{"gauges":["cpu.total"]}"#.utf8)
        )
        #expect(decoded.gaugeOrder == [MetricID("cpu.total")])
        #expect(decoded.gaugeSize == PanelSize.gauge.initial)
        #expect(decoded.groupOrder(in: .sensors).isEmpty)
    }

    @Test("A size stored out of range is clamped when it is decoded")
    func decodingClampsSizes() throws {
        let json = """
        {"gauges":[],"performance":[],"sensors":[],
         "gaugeSize":9000,"chartWidth":1,"chartHeight":1}
        """
        let decoded = try JSONDecoder().decode(
            PanelArrangement.self, from: Data(json.utf8)
        )
        #expect(decoded.gaugeSize == PanelSize.gauge.maximum)
        #expect(decoded.chartWidth == PanelSize.chartWidth.minimum)
    }

    @Test("Round-trips through JSON unchanged")
    func codableRoundTrip() throws {
        var arrangement = PanelArrangement.defaults(for: Self.descriptors())
        arrangement.moveGroup("Temperature", to: .performance, before: "Disk")
        arrangement.gaugeSize = 200
        let data = try JSONEncoder().encode(arrangement)
        #expect(try JSONDecoder().decode(PanelArrangement.self, from: data) == arrangement)
    }

    @Test("A group named on both sides of the rule draws one card, not two")
    func duplicateGroupIsDropped() {
        let arrangement = PanelArrangement(
            performance: ["Disk", "Disk", "CPU"], sensors: ["Disk", "Temperature"]
        )
        #expect(arrangement.groupOrder(in: .performance) == ["Disk", "CPU"])
        #expect(arrangement.groupOrder(in: .sensors) == ["Temperature"])
    }
}
