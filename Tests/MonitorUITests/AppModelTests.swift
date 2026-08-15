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
}
