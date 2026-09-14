import MonitorCore
@testable import MonitorPrometheus
import MonitorSources
import Testing

@Suite("Prometheus mapping")
struct MappingTests {
    @Test("each SMC temperature maps to the temperature family with a sensor label")
    func temperatures() {
        #expect(
            PrometheusMapping.map(SMCSource.cpuTemperature)
                == MappedMetric(
                    familyName: "macos_smc_temperature_celsius",
                    help: PrometheusMapping.temperatureHelp,
                    labels: [PrometheusLabel(name: "sensor", value: "cpu")]
                )
        )
        #expect(
            PrometheusMapping.map(SMCSource.enclosureTemperature)?.labels
                == [PrometheusLabel(name: "sensor", value: "enclosure")]
        )
    }

    @Test("power rails carry a rail label")
    func power() {
        #expect(
            PrometheusMapping.map(SMCSource.inputPower)?.labels
                == [PrometheusLabel(name: "rail", value: "input")]
        )
        #expect(
            PrometheusMapping.map(SMCSource.socPower)?.labels
                == [PrometheusLabel(name: "rail", value: "soc")]
        )
        #expect(PrometheusMapping.map(SMCSource.socPower)?
            .familyName == "macos_smc_power_watts")
    }

    @Test("a fan id carries its one-based index as a fan label")
    func fans() {
        #expect(
            PrometheusMapping.map(SMCSource.fanSpeed(2))
                == MappedMetric(
                    familyName: "macos_smc_fan_rpm", help: PrometheusMapping.fanHelp,
                    labels: [PrometheusLabel(name: "fan", value: "2")]
                )
        )
    }

    @Test("gpu metrics map to unlabelled families")
    func gpu() {
        #expect(PrometheusMapping.map(GPUSource.utilization)?
            .familyName == "macos_gpu_utilization_ratio")
        #expect(PrometheusMapping.map(GPUSource.vramUsed)?
            .familyName == "macos_gpu_vram_used_bytes")
        #expect(PrometheusMapping.map(GPUSource.utilization)?.labels == [])
    }

    @Test("a non-gap metric does not map")
    func nonGap() {
        #expect(PrometheusMapping.map(MetricID("cpu.total")) == nil)
        #expect(PrometheusMapping.map(MetricID("memory.used")) == nil)
        #expect(PrometheusMapping.map(MetricID("net.bits.in")) == nil)
    }

    @Test("families groups entries by name and sorts within a family by label")
    func builder() throws {
        let entries: [(MappedMetric, Double)] = try [
            (#require(PrometheusMapping.map(SMCSource.fanSpeed(2))), 3400),
            (#require(PrometheusMapping.map(SMCSource.fanSpeed(1))), 3187),
        ]
        let families = PrometheusFamilyBuilder.families(from: entries)
        #expect(families.count == 1)
        #expect(families[0].name == "macos_smc_fan_rpm")
        #expect(families[0].samples.map(\.value) == [
            3187,
            3400,
        ]) // fan="1" sorts before fan="2"
    }
}
