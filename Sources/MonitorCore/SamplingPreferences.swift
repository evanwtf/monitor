import Foundation

/// How often each kind of source is read.
///
/// Two rates rather than one, because the two answer to different hardware.
/// Disk and network counters are current whenever they are asked, so the rate
/// there is a choice about how much detail you want. The SMC is not: it
/// refreshes its temperature and power keys **once a second**, and reading them
/// at 2 Hz returns the same bits twice.
///
/// That was measured rather than assumed — see `docs/sensors.md`. On a 16-inch
/// MacBook Pro under load, sampling sensors at 0.5 s and at 1 s produce
/// bit-identical traces; the difference only appears at 2 s and beyond.
public struct SamplingPreferences: Codable, Equatable, Sendable {
    /// How often counters and load are read: the master clock.
    public var performance: TimeInterval
    /// How often sensors are read. Never faster than the master clock, because
    /// sensors are sampled on it rather than on a second timer of their own.
    public var sensors: TimeInterval

    public static let performanceChoices: [TimeInterval] = [0.25, 0.5, 1, 2]

    /// 10 s is absent on purpose. At that interval a die that climbed 20 °C
    /// between two readings shows as a straight line between them, and the
    /// chart says the machine warmed gently when it did not.
    public static let sensorChoices: [TimeInterval] = [1, 2, 5]

    public static let `default` = SamplingPreferences(performance: 0.5, sensors: 1)

    public init(performance: TimeInterval = 0.5, sensors: TimeInterval = 1) {
        self.performance = performance
        self.sensors = sensors
    }

    /// What the sensors are actually read at.
    ///
    /// Sensors ride the master clock, so their interval is rounded up to a
    /// whole number of ticks. Asking for 1 s while the master runs at 2 s gets
    /// 2 s — the slower of the two wins, and the panel says so rather than
    /// claiming a rate it cannot deliver.
    public var effectiveSensorInterval: TimeInterval {
        performance * Double(sensorTickDivisor)
    }

    /// How many master ticks pass between sensor reads. Always at least one.
    public var sensorTickDivisor: Int {
        guard performance > 0 else { return 1 }
        return max(1, Int((sensors / performance).rounded()))
    }
}
