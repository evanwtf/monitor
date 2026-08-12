import Foundation
import MonitorCore

/// Temperatures, fan speeds and power draw, from the SMC.
///
/// Every reading here is unprivileged: no helper tool, no root, no
/// `powermetrics`. The cost is that the SMC publishes a couple of thousand
/// four-character keys with no documentation of what any of them measure, so
/// this file is mostly about deciding which keys are safe to name.
///
/// Two rules keep it honest:
///
///  - **Sensors are found, not assumed.** The key table is scanned once at
///    launch for the temperature and fan ranges, and a metric exists only if
///    this machine actually publishes sensors for it. A fanless Mac gets no
///    fan card at all rather than a card reading zero, and an Intel Mac's
///    `TC0P` lands in the same CPU metric as Apple silicon's `Tp01`.
///  - **A key is only named if its meaning was checked.** The two power keys
///    were confirmed against independent sources on Apple silicon: `PDTR`
///    equals `VD0R × ID0R`, the DC input rail's own volts and amps, and `PHPS`
///    tracks IOReport's Energy Model total for CPU + GPU + DRAM to within a
///    few percent under load. Keys that merely look like power — and there are
///    fifty — are left alone, because a plausible wrong watt figure is worse
///    than no watt figure.
///
/// Fan speed is read-only here. Reading the SMC needs no privileges; *writing*
/// it — setting a fan speed — does, and this type has no code path that writes.
public final class SMCSource: MetricSource, @unchecked Sendable {
    public let id = "sensors"

    public static let cpuTemperature = MetricID("sensor.temperature.cpu")
    public static let gpuTemperature = MetricID("sensor.temperature.gpu")
    public static let storageTemperature = MetricID("sensor.temperature.storage")
    public static let batteryTemperature = MetricID("sensor.temperature.battery")
    public static let enclosureTemperature = MetricID("sensor.temperature.enclosure")
    public static let ambientTemperature = MetricID("sensor.temperature.ambient")
    public static let inputPower = MetricID("sensor.power.input")
    public static let socPower = MetricID("sensor.power.soc")

    public static func fanSpeed(_ index: Int) -> MetricID {
        MetricID("sensor.fan.\(index).speed")
    }

    /// A metric and the keys that feed it.
    private struct Sensor {
        let descriptor: MetricDescriptor
        let keys: [SMC.Key]
        /// Temperatures take the hottest of their keys; everything else has
        /// one key and takes it.
        let hottest: Bool
    }

    private let smc: SMC?
    private let sensors: [Sensor]

    public let descriptors: [MetricDescriptor]

    public init() {
        guard let smc = try? SMC() else {
            self.smc = nil
            sensors = []
            descriptors = []
            log.notice("SMC unavailable; sensor metrics will not be offered")
            return
        }
        self.smc = smc
        sensors = Self.discover(with: smc)
        descriptors = sensors.map(\.descriptor)
    }

    public func read(at timestamp: TimeInterval) throws -> SampleBatch {
        guard let smc else { throw MetricSourceError.unavailable("SMC") }
        guard !sensors.isEmpty else {
            throw MetricSourceError.unavailable("SMC sensors")
        }

        var values: [MetricID: Double] = [:]
        for sensor in sensors {
            let readings = sensor.keys.compactMap { key in
                smc.value(of: key).flatMap { Self.plausible($0, for: sensor) }
            }
            guard let value = sensor.hottest ? readings.max() : readings.first else { continue }
            values[sensor.descriptor.id] = value
        }

        guard !values.isEmpty else {
            throw MetricSourceError.unavailable("SMC sensor readings")
        }
        return SampleBatch(timestamp: timestamp, values: values)
    }

    // MARK: - Deciding what this machine has

    /// Which keys feed which metric.
    ///
    /// Apple silicon numbers its die sensors `Tp…` for CPU cores, `Te…` for
    /// efficiency cores on the machines that name them separately, and `Tg…`
    /// for the GPU; Intel Macs use a handful of fixed names. Both are matched,
    /// so this is one source rather than two.
    ///
    /// The Intel names are listed exactly rather than by prefix on purpose:
    /// `TC` as a prefix would also swallow `TCHP`, the charger, and report a
    /// warm power brick as a warm CPU.
    private static func discover(with smc: SMC) -> [Sensor] {
        let temperatures = (try? smc.keys(withPrefix: "T")) ?? []
        func matching(prefixes: [String], exact: [String] = []) -> [SMC.Key] {
            let wanted = temperatures.filter { key in
                prefixes.contains(where: { key.name.hasPrefix($0) }) || exact.contains(key.name)
            }
            // Capped because reading a key costs an IOKit round trip and a
            // machine can publish twenty CPU die sensors. Six of them, read
            // twice a second forever, is a cost worth paying; twenty is not,
            // and they move together anyway.
            return Array(wanted.prefix(maximumKeysPerSensor))
        }

        var found: [Sensor] = []

        func addTemperature(
            _ metric: MetricID, _ name: String, keys: [SMC.Key]
        ) {
            guard !keys.isEmpty else { return }
            found.append(Sensor(
                descriptor: MetricDescriptor(
                    id: metric, name: name, group: "Temperature", unit: .celsius,
                    // Pinned rather than scaled to the data, for the same
                    // reason a CPU chart is pinned to 0–100%: a room-
                    // temperature machine auto-scaled to its own 2 °C of
                    // drift looks like something is wrong. 110 is where
                    // Apple silicon throttles, so the top of the chart means
                    // something.
                    nominalMaximum: temperatureCeiling
                ),
                keys: keys,
                hottest: true
            ))
        }

        addTemperature(
            cpuTemperature, "CPU",
            keys: matching(
                prefixes: ["Tp", "Te"],
                exact: ["TC0P", "TC0D", "TC0E", "TC0F", "TCXC", "TCAD"]
            )
        )
        addTemperature(
            gpuTemperature, "GPU",
            keys: matching(prefixes: ["Tg"], exact: ["TG0P", "TG0D"])
        )
        addTemperature(
            storageTemperature, "SSD",
            keys: matching(prefixes: ["TH0"])
        )
        addTemperature(
            batteryTemperature, "Battery",
            keys: temperatures.filter { $0.name.hasPrefix("TB") && $0.name.hasSuffix("T") }
        )
        addTemperature(
            enclosureTemperature, "Enclosure",
            keys: temperatures.filter { $0.name.hasPrefix("Ts") && $0.name.hasSuffix("P") }
        )
        addTemperature(
            ambientTemperature, "Ambient",
            keys: temperatures.filter { $0.name.hasPrefix("TA") && $0.name.hasSuffix("P") }
        )

        for (metric, name, key) in [
            (inputPower, "Input", "PDTR"), (socPower, "SoC", "PHPS"),
        ] {
            guard let key = smc.key(named: key) else { continue }
            found.append(Sensor(
                descriptor: MetricDescriptor(
                    id: metric, name: name, group: "Power", unit: .watts
                ),
                keys: [key],
                hottest: false
            ))
        }

        found.append(contentsOf: fans(with: smc))
        return found
    }

    /// Fans, if this machine has any.
    ///
    /// `F0Ac` is the first fan's actual speed and `F0Mx` its maximum, which
    /// becomes the top of the chart — a fan at 2000 rpm means nothing until
    /// you know whether it tops out at 2500 or 6000. Machines are numbered
    /// from zero and the count stops at the first gap rather than trusting
    /// `FNum`, which is missing on some models that do have fans.
    private static func fans(with smc: SMC) -> [Sensor] {
        var found: [Sensor] = []
        for index in 0..<maximumFans {
            guard let key = smc.key(named: "F\(index)Ac") else { break }
            let maximum = smc.key(named: "F\(index)Mx").flatMap { smc.value(of: $0) }
            found.append(Sensor(
                descriptor: MetricDescriptor(
                    id: fanSpeed(index + 1),
                    // One-based in the UI: nobody calls the first fan "Fan 0".
                    name: "Fan \(index + 1)",
                    group: "Fans",
                    unit: .rpm,
                    nominalMaximum: maximum.flatMap { $0 > 0 ? $0 : nil }
                ),
                keys: [key],
                hottest: false
            ))
        }
        return found
    }

    /// Rejects readings that cannot be what the sensor claims to measure.
    ///
    /// The SMC reports 0 for a sensor a model does not populate — the key
    /// exists, the hardware behind it does not — and an idle die is never 0 °C
    /// in a room, so a zero temperature is a missing sensor rather than a cold
    /// one. Power genuinely is zero when a laptop is running on battery, so
    /// zero watts is kept.
    private static func plausible(_ value: Double, for sensor: Sensor) -> Double? {
        switch sensor.descriptor.unit {
        case .celsius: (value > 0 && value < 150) ? value : nil
        case .watts: (value >= 0 && value < 1000) ? value : nil
        case .rpm: (value >= 0 && value < 20000) ? value : nil
        default: value
        }
    }

    /// Where Apple silicon starts throttling, and so the top of a chart.
    private static let temperatureCeiling = 110.0
    private static let maximumKeysPerSensor = 6
    private static let maximumFans = 4
}
