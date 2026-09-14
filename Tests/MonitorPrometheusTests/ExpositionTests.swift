@testable import MonitorPrometheus
import Testing

@Suite("Exposition format")
struct ExpositionTests {
    @Test(
        "a family renders HELP, TYPE and one line per series, in the given order, with a trailing newline"
    )
    func rendersFamily() {
        // The renderer preserves the order it is handed; the family builder is
        // what sorts (see MappingTests.builder). So these are already in order.
        let family = PrometheusFamily(
            name: "macos_smc_temperature_celsius",
            help: "SMC temperature sensor reading, in degrees Celsius.",
            samples: [
                PrometheusSample(
                    labels: [PrometheusLabel(name: "sensor", value: "cpu")],
                    value: 72.33
                ),
                PrometheusSample(
                    labels: [PrometheusLabel(name: "sensor", value: "gpu")],
                    value: 76.78
                ),
            ]
        )
        let expected = [
            "# HELP macos_smc_temperature_celsius SMC temperature sensor reading, in degrees Celsius.",
            "# TYPE macos_smc_temperature_celsius gauge",
            #"macos_smc_temperature_celsius{sensor="cpu"} 72.33"#,
            #"macos_smc_temperature_celsius{sensor="gpu"} 76.78"#,
            "",
        ].joined(separator: "\n")
        #expect(renderExposition([family]) == expected)
    }

    @Test("an integral value drops the decimal point")
    func integralValue() {
        let f = PrometheusFamily(
            name: "macos_smc_fan_rpm", help: "h",
            samples: [PrometheusSample(
                labels: [PrometheusLabel(name: "fan", value: "1")],
                value: 3187
            )]
        )
        #expect(renderExposition([f]).contains("macos_smc_fan_rpm{fan=\"1\"} 3187\n"))
    }

    @Test("a family with no samples is omitted entirely")
    func emptyFamilyOmitted() {
        #expect(renderExposition([PrometheusFamily(name: "x", help: "h", samples: [])]).isEmpty)
    }

    @Test("a label value with a quote or backslash is escaped")
    func escaping() {
        let f = PrometheusFamily(
            name: "x", help: "h",
            samples: [PrometheusSample(
                labels: [PrometheusLabel(name: "k", value: #"a"b\c"#)],
                value: 1
            )]
        )
        #expect(renderExposition([f]).contains(#"x{k="a\"b\\c"} 1"#))
    }

    @Test("an unlabelled metric renders with no braces")
    func noLabels() {
        let f = PrometheusFamily(
            name: "macos_gpu_utilization_ratio", help: "h",
            samples: [PrometheusSample(labels: [], value: 0.99)]
        )
        #expect(renderExposition([f]).contains("macos_gpu_utilization_ratio 0.99\n"))
    }
}
