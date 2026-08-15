import Foundation
@testable import MonitorCore
import Testing

@Suite("SamplingPreferences")
struct SamplingPreferencesTests {
    @Test("sensors ride the master clock as a whole number of ticks")
    func divisor() {
        #expect(SamplingPreferences(performance: 0.5, sensors: 1).sensorTickDivisor == 2)
        #expect(SamplingPreferences(performance: 0.5, sensors: 2).sensorTickDivisor == 4)
        #expect(SamplingPreferences(performance: 0.5, sensors: 5).sensorTickDivisor == 10)
        #expect(SamplingPreferences(performance: 0.25, sensors: 1).sensorTickDivisor == 4)
        #expect(SamplingPreferences(performance: 1, sensors: 1).sensorTickDivisor == 1)
    }

    /// The slower of the two wins. Sensors are sampled on the master clock, so
    /// asking for 1 s while it runs at 2 s cannot deliver 1 s, and claiming
    /// otherwise would put a rate on screen the app does not honour.
    @Test("sensors never run faster than the master clock")
    func clampedToMasterClock() {
        let slow = SamplingPreferences(performance: 2, sensors: 1)
        #expect(slow.sensorTickDivisor == 1)
        #expect(slow.effectiveSensorInterval == 2)
    }

    @Test("the effective interval is what the divisor actually produces")
    func effective() {
        #expect(SamplingPreferences(performance: 0.5, sensors: 2).effectiveSensorInterval == 2)
        #expect(SamplingPreferences(performance: 0.25, sensors: 5).effectiveSensorInterval == 5)
    }

    /// A zero would divide by zero on the way to a tick count.
    @Test("a nonsense master clock does not divide by zero")
    func degenerate() {
        #expect(SamplingPreferences(performance: 0, sensors: 1).sensorTickDivisor == 1)
    }

    @Test("defaults are half a second and one second")
    func defaults() {
        #expect(SamplingPreferences.default.performance == 0.5)
        #expect(SamplingPreferences.default.sensors == 1)
        // 1 s is the floor because the SMC refreshes at 1 Hz; offering faster
        // would be offering the same bits again.
        #expect(SamplingPreferences.sensorChoices.first == 1)
    }

    @Test("preferences round-trip through JSON")
    func roundTrip() throws {
        let preferences = SamplingPreferences(performance: 0.25, sensors: 5)
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(SamplingPreferences.self, from: data) == preferences)
    }
}
