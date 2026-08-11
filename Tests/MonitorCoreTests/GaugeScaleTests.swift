import Foundation
@testable import MonitorCore
import Testing

@Suite("GaugeScale")
struct GaugeScaleTests {
    @Test("snaps full scale to 1, 2 or 5 times a power of ten")
    func snapping() {
        #expect(GaugeScale.snap(0.7) == 1)
        #expect(GaugeScale.snap(1.5) == 2)
        #expect(GaugeScale.snap(3) == 5)
        #expect(GaugeScale.snap(6) == 10)
        #expect(GaugeScale.snap(370_000_000) == 500_000_000)
    }

    @Test("never scales below the floor")
    func floor() {
        var scale = GaugeScale(floor: 1000)
        scale.update(value: 3, at: 0)
        #expect(scale.fullScale == 1000)
    }

    @Test("rises at once when a reading exceeds full scale")
    func risesImmediately() {
        var scale = GaugeScale(floor: 100)
        scale.update(value: 900, at: 0)
        #expect(scale.fullScale == 1000)
        #expect(scale.deflection(for: 900) == 0.9)
    }

    /// The dial must not rescale the instant traffic stops, or the needle
    /// appears to move when the value did not.
    @Test("does not scale down until the peak has been quiet")
    func fallsSlowly() {
        var scale = GaugeScale(floor: 10, decayInterval: 15)
        scale.update(value: 900, at: 0)
        #expect(scale.fullScale == 1000)

        scale.update(value: 5, at: 5)
        #expect(scale.fullScale == 1000, "scaled down while the peak was still recent")

        // The window that contained the spike still holds the dial up.
        scale.update(value: 5, at: 20)
        #expect(scale.fullScale == 1000)

        // The next quiet window lets it fall.
        scale.update(value: 5, at: 40)
        #expect(scale.fullScale < 1000)
    }

    /// The failure this guards against: one big spike pinning the dial forever,
    /// so every later reading sits against the stop and the gauge is useless.
    @Test("a single spike does not pin the dial permanently")
    func spikeDoesNotPin() {
        var scale = GaugeScale(floor: 10, decayInterval: 15)
        scale.update(value: 1_000_000, at: 0)
        for step in stride(from: 1.0, through: 200.0, by: 1.0) {
            scale.update(value: 20, at: step)
        }
        #expect(scale.fullScale <= 50, "the dial never recovered from the spike")
    }

    @Test("clamps deflection to the dial")
    func deflection() {
        var scale = GaugeScale(floor: 100)
        scale.update(value: 50, at: 0)
        #expect(scale.deflection(for: -5) == 0)
        #expect(scale.deflection(for: 1_000_000) == 1)
    }
}

@Suite("Format")
struct FormatTests {
    @Test("uses decimal byte units")
    func bytes() {
        #expect(Format.bytes(1000) == "1.0 kB")
        #expect(Format.bytes(1_500_000, perSecond: true) == "1.5 MB/s")
        #expect(Format.bytes(0) == "0 B")
    }

    /// The gauge draws the number and the unit separately, so the two halves
    /// must describe the same scaled value — 480 with "MB/s", never 480 with
    /// "GB/s".
    @Test("magnitude and unit label agree")
    func gaugeReadout() {
        let value = 480_000_000.0
        #expect(Format.magnitude(value, unit: .bytesPerSecond) == "480")
        #expect(Format.unitLabel(value, unit: .bytesPerSecond) == "MB/s")
    }

    @Test("scales durations to readable units")
    func durations() {
        #expect(Format.duration(0.04) == "40.0 ms")
        #expect(Format.duration(0.000004) == "4 µs")
    }
}
