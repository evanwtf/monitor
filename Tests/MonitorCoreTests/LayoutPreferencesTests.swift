import Foundation
@testable import MonitorCore
import Testing

@Suite("LayoutPreferences")
struct LayoutPreferencesTests {
    /// A stand-in registry: one metric from each of the three cases the
    /// defaults distinguish — a dial, a chart-only group, and a group nothing
    /// draws until somebody asks for it.
    static let descriptors = [
        MetricDescriptor(
            id: MetricID("disk.bytes.read"), name: "Read", group: "Disk",
            unit: .bytesPerSecond, kind: .counter
        ),
        MetricDescriptor(
            id: MetricID("cpu.total"), name: "Total", group: "CPU", unit: .fraction
        ),
        MetricDescriptor(
            id: MetricID("disk.ops.read"), name: "Reads", group: "Disk Ops",
            unit: .operationsPerSecond, kind: .counter
        ),
    ]

    @Test("Defaults draw the panel the app ships with")
    func defaults() {
        let layout = LayoutPreferences.defaults(for: Self.descriptors)

        #expect(layout.showsGauge(MetricID("disk.bytes.read")))
        #expect(layout.showsChart(MetricID("disk.bytes.read")))

        // A level, so a chart and no dial.
        #expect(!layout.showsGauge(MetricID("cpu.total")))
        #expect(layout.showsChart(MetricID("cpu.total")))

        // Diagnostic detail: neither, until somebody ticks it.
        #expect(!layout.showsGauge(MetricID("disk.ops.read")))
        #expect(!layout.showsChart(MetricID("disk.ops.read")))
    }

    @Test("Setting one column leaves the other alone")
    func columnsAreIndependent() {
        var layout = LayoutPreferences.defaults(for: Self.descriptors)

        layout.setGauge(true, for: MetricID("cpu.total"))
        #expect(layout.showsGauge(MetricID("cpu.total")))
        #expect(layout.showsChart(MetricID("cpu.total")))

        layout.setChart(false, for: MetricID("cpu.total"))
        #expect(layout.showsGauge(MetricID("cpu.total")))
        #expect(!layout.showsChart(MetricID("cpu.total")))
    }

    /// The case this exists for: a later version adds a metric, or a machine
    /// starts reporting a sensor it did not before. The new one gets its
    /// default; nothing already chosen moves.
    @Test("A metric the stored layout never saw gets its default")
    func newMetricAdoptsDefaults() {
        var stored = LayoutPreferences.defaults(for: [Self.descriptors[0]])
        stored.setGauge(false, for: MetricID("disk.bytes.read"))

        let merged = stored.adoptingDefaults(for: Self.descriptors)

        // The choice already made survives the merge.
        #expect(!merged.showsGauge(MetricID("disk.bytes.read")))
        #expect(merged.showsChart(MetricID("disk.bytes.read")))
        // The metric it had never seen picks up the shipped layout.
        #expect(merged.showsChart(MetricID("cpu.total")))
        #expect(!merged.showsChart(MetricID("disk.ops.read")))
    }

    /// A metric switched off is not the same as one never seen, so the merge
    /// must not switch it back on.
    @Test("Turning everything off survives a merge")
    func everythingOffSurvives() {
        var layout = LayoutPreferences()
        for descriptor in Self.descriptors {
            layout.setGauge(false, for: descriptor.id)
            layout.setChart(false, for: descriptor.id)
        }

        let merged = layout.adoptingDefaults(for: Self.descriptors)

        for descriptor in Self.descriptors {
            #expect(!merged.showsGauge(descriptor.id))
            #expect(!merged.showsChart(descriptor.id))
        }
    }

    @Test("A layout round-trips through JSON")
    func roundTrip() throws {
        var layout = LayoutPreferences.defaults(for: Self.descriptors)
        layout.setChart(true, for: MetricID("disk.ops.read"))

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(LayoutPreferences.self, from: data)

        #expect(decoded == layout)
        #expect(decoded.showsChart(MetricID("disk.ops.read")))
    }
}
