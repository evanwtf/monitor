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

    /// Half a second to five, in half seconds.
    ///
    /// The floor is half a second because that is where the gauges stop
    /// stepping visibly: the needle animation can smooth a gap but cannot
    /// invent detail that was never sampled.
    public static let performanceChoices: [TimeInterval] =
        stride(from: 0.5, through: 5.0, by: 0.5).map(\.self)

    /// One second to five, in seconds.
    ///
    /// One is the floor because the SMC refreshes at 1 Hz and anything faster
    /// re-reads the same bits. Five is the ceiling because past it a die that
    /// climbed 20 °C between readings draws as a straight line, and the chart
    /// then says the machine warmed gently when it did not.
    public static let sensorChoices: [TimeInterval] = [1, 2, 3, 4, 5]

    public static let `default` = SamplingPreferences(performance: 0.5, sensors: 1)

    public init(performance: TimeInterval = 0.5, sensors: TimeInterval = 1) {
        self.performance = performance
        self.sensors = sensors
    }

    /// What the sensors are actually read at.
    ///
    /// Sensors ride the master clock, so their interval can only be a whole
    /// number of ticks. Two things follow, and the panel spells both out rather
    /// than showing a rate it does not honour:
    ///
    ///  - Asking for 1 s while the master runs at 2 s gets 2 s. Sensors cannot
    ///    be read more often than the clock they ride.
    ///  - Asking for 2 s while the master runs at 1.5 s gets 1.5 s, because 2
    ///    is not a multiple of 1.5 and one tick is nearer than two.
    public var effectiveSensorInterval: TimeInterval {
        performance * Double(sensorTickDivisor)
    }

    /// Whether the rate asked for is the rate delivered.
    public var sensorIntervalIsExact: Bool {
        abs(effectiveSensorInterval - sensors) < 0.001
    }

    /// How many master ticks pass between sensor reads. Always at least one.
    public var sensorTickDivisor: Int {
        guard performance > 0 else { return 1 }
        return max(1, Int((sensors / performance).rounded()))
    }
}
