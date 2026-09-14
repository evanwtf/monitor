import Foundation
import MonitorCore
@testable import MonitorExporter
import Testing

/// A source whose reading is fixed, so the handler can be tested without hardware.
private struct FakeSource: MetricSource {
    let id = "fake"
    var descriptors: [MetricDescriptor] { [] }
    let batch: SampleBatch?
    func read(at _: TimeInterval) throws -> SampleBatch {
        guard let batch else { throw MetricSourceError.unavailable("fake") }
        return batch
    }
}

@Suite("Metrics handler")
struct MetricsHandlerTests {
    @Test("maps known sensors, drops unmapped metrics, and always emits build_info")
    func exposition() {
        let batch = SampleBatch(timestamp: 0, samples: [
            Sample(metric: MetricID("sensor.temperature.cpu"), timestamp: 0, value: 72.33),
            Sample(metric: MetricID("cpu.total"), timestamp: 0, value: 0.1),
        ])
        let text = MetricsHandler(sources: [FakeSource(batch: batch)]).exposition(now: 0)
        #expect(text.contains(#"macos_smc_temperature_celsius{sensor="cpu"} 72.33"#))
        #expect(!text.contains("cpu.total"))
        #expect(text.contains("monitor_exporter_build_info"))
    }

    @Test("a source that cannot read contributes no series — never a zero")
    func failingSource() {
        let text = MetricsHandler(sources: [FakeSource(batch: nil)]).exposition(now: 0)
        #expect(!text.contains("macos_"))
        #expect(text.contains("monitor_exporter_build_info")) // build_info still answers
    }
}
