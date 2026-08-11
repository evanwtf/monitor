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
    /// appears to move when the value did not. The clock starts when the value
    /// drops below the threshold, so quiet time is counted from t=5 here.
    @Test("does not scale down until the value has been quiet")
    func fallsSlowly() {
        var scale = GaugeScale(floor: 10, decayInterval: 15)
        scale.update(value: 900, at: 0)
        #expect(scale.fullScale == 1000)

        scale.update(value: 5, at: 5)
        #expect(scale.fullScale == 1000, "scaled down the instant traffic dropped")

        scale.update(value: 5, at: 19)
        #expect(scale.fullScale == 1000, "scaled down before the interval was up")

        scale.update(value: 5, at: 21)
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

@Suite("ScaleLadder")
struct ScaleLadderTests {
    @Test("the decade ladder rounds up to a power of ten")
    func decadeSnapping() {
        #expect(ScaleLadder.decade.snap(10_000_000) == 10_000_000)
        #expect(ScaleLadder.decade.snap(10_000_001) == 100_000_000)
        #expect(ScaleLadder.decade.snap(90_000_000) == 100_000_000)
        #expect(ScaleLadder.decade.snap(100_000_000) == 100_000_000)
        #expect(ScaleLadder.decade.snap(101_000_000) == 1_000_000_000)
    }

    @Test("the step below is the next rung down, on or off the ladder")
    func stepBelow() {
        #expect(ScaleLadder.decade.step(below: 1000) == 100)
        #expect(ScaleLadder.decade.step(below: 100) == 10)
        // A value between rungs still has a well-defined rung below it.
        #expect(ScaleLadder.decade.step(below: 150) == 100)

        #expect(ScaleLadder.oneTwoFive.step(below: 1000) == 500)
        #expect(ScaleLadder.oneTwoFive.step(below: 500) == 200)
        #expect(ScaleLadder.oneTwoFive.step(below: 200) == 100)
        #expect(ScaleLadder.oneTwoFive.step(below: 370) == 200)
        #expect(ScaleLadder.oneTwoFive.step(below: 0) == nil)
    }

    /// `log10` is not exact for every power of ten, and a mantissa that came
    /// back as 9.999999 instead of 1 would put a scale a whole decade wrong.
    @Test("powers of ten do not fall through a floating point crack")
    func exactPowers() {
        for exponent in 0...12 {
            let value = pow(10.0, Double(exponent))
            #expect(ScaleLadder.decade.snap(value) == value, "snap moved 1e\(exponent)")
            #expect(
                ScaleLadder.decade.step(below: value) == value / 10,
                "step below 1e\(exponent) was wrong"
            )
        }
    }
}

/// The behaviour the throughput dials are specified by: start at ten, climb by
/// decades, and hold the scale you were pushed to for ten minutes.
@Suite("Decade gauge scale")
struct DecadeGaugeScaleTests {
    /// Ten megabits a second, the scale a network dial starts and mostly lives
    /// on. Written in full because the thresholds under test are the product
    /// decision, not an implementation detail.
    private let mega = 1_000_000.0

    private func networkScale() -> GaugeScale {
        GaugeScale(floor: 10_000_000, decayInterval: 600, ladder: .decade)
    }

    /// Hold a value for a stretch, at the rate the app actually samples.
    ///
    /// The decay is about how long a value has been low, so a test that jumped
    /// straight from t=0 to t=601 would be describing a machine that samples
    /// twice an hour, and would prove nothing about this one.
    private func hold(
        _ scale: inout GaugeScale,
        at value: Double,
        from start: TimeInterval,
        to end: TimeInterval,
        every interval: TimeInterval = 0.5
    ) {
        for timestamp in stride(from: start, through: end, by: interval) {
            scale.update(value: value, at: timestamp)
        }
    }

    @Test("starts at ten")
    func startsAtTen() {
        let scale = networkScale()
        #expect(scale.fullScale == 10 * mega)
    }

    @Test("climbs a decade at a time as traffic exceeds the scale")
    func climbs() {
        var scale = networkScale()
        scale.update(value: 9 * mega, at: 0)
        #expect(scale.fullScale == 10 * mega, "a reading under full scale moved the dial")

        scale.update(value: 11 * mega, at: 1)
        #expect(scale.fullScale == 100 * mega)

        scale.update(value: 90 * mega, at: 2)
        #expect(scale.fullScale == 100 * mega, "90 fits on the 100 scale")

        scale.update(value: 150 * mega, at: 3)
        #expect(scale.fullScale == 1000 * mega)
    }

    @Test("holds the raised scale for the full ten minutes")
    func holds() {
        var scale = networkScale()
        scale.update(value: 90 * mega, at: 0)
        #expect(scale.fullScale == 100 * mega)

        hold(&scale, at: 1 * mega, from: 0.5, to: 599)
        #expect(scale.fullScale == 100 * mega, "the dial came down early")
    }

    @Test("comes back down after ten quiet minutes")
    func comesDown() {
        var scale = networkScale()
        scale.update(value: 90 * mega, at: 0)
        hold(&scale, at: 1 * mega, from: 0.5, to: 620)
        #expect(scale.fullScale == 10 * mega)
    }

    /// Without the hysteresis band, a workload sitting just under full scale
    /// rescales the dial forever, and the needle moves while the value does
    /// not.
    @Test("traffic close to the lower scale keeps the higher one")
    func hysteresis() {
        var scale = networkScale()
        scale.update(value: 90 * mega, at: 0)
        // 9.5 is below the 10 rung, but not below 90% of it.
        hold(&scale, at: 9.5 * mega, from: 0.5, to: 1800)
        #expect(scale.fullScale == 100 * mega, "the dial flapped down on a near-threshold load")

        hold(&scale, at: 8 * mega, from: 1800.5, to: 2420)
        #expect(scale.fullScale == 10 * mega, "the dial never came down once traffic was clear")
    }

    /// Ten minutes of quiet should return the dial to the bottom, not start a
    /// half-hour walk down during which every reading is squashed flat.
    @Test("descends as far as the quiet justifies, not one rung at a time")
    func descendsAllTheWay() {
        var scale = networkScale()
        scale.update(value: 900 * mega, at: 0)
        #expect(scale.fullScale == 1000 * mega)

        hold(&scale, at: 0.5 * mega, from: 0.5, to: 620)
        #expect(scale.fullScale == 10 * mega)
    }

    @Test("never falls below its floor")
    func floor() {
        var scale = networkScale()
        hold(&scale, at: 0, from: 0, to: 3000, every: 10)
        #expect(scale.fullScale == 10 * mega)
    }

    /// The ten minutes is measured from the moment traffic dropped, so a spike
    /// arriving late in a quiet stretch gets its own full ten minutes rather
    /// than inheriting whatever was left of the previous one.
    @Test("a spike restarts the quiet period")
    func spikeRestartsTheQuietPeriod() {
        var scale = networkScale()
        hold(&scale, at: 1 * mega, from: 0, to: 598)
        scale.update(value: 90 * mega, at: 599)
        #expect(scale.fullScale == 100 * mega)

        hold(&scale, at: 1 * mega, from: 599.5, to: 1100)
        #expect(scale.fullScale == 100 * mega, "the spike inherited the earlier quiet period")

        hold(&scale, at: 1 * mega, from: 1100.5, to: 1220)
        #expect(scale.fullScale == 10 * mega)
    }

    /// A brief burst part-way through the quiet period resets it. Otherwise a
    /// dial could drop its scale moments after traffic that needed it.
    @Test("traffic during the quiet period restarts the clock")
    func trafficResetsTheClock() {
        var scale = networkScale()
        scale.update(value: 90 * mega, at: 0)
        hold(&scale, at: 1 * mega, from: 0.5, to: 550)
        scale.update(value: 50 * mega, at: 551)
        hold(&scale, at: 1 * mega, from: 551.5, to: 1100)
        #expect(scale.fullScale == 100 * mega, "a burst at 551 s did not restart the clock")

        hold(&scale, at: 1 * mega, from: 1100.5, to: 1180)
        #expect(scale.fullScale == 10 * mega)
    }

    /// The mark shows why the dial is on the scale it is on, which is the only
    /// thing that makes a raised scale readable when nothing is happening.
    @Test("the memory mark holds the reading that raised the scale")
    func peakExplainsTheScale() {
        var scale = networkScale()
        scale.update(value: 90 * mega, at: 0)
        hold(&scale, at: 1 * mega, from: 0.5, to: 400)
        #expect(scale.peak == 90 * mega)
        #expect(scale.deflection(for: scale.peak) == 0.9)
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

    /// The unit under a needle must not change while you are reading it, so
    /// throughput never rescales: disk is MB/s and network is Mbit/s at every
    /// magnitude, from a trickle to a saturated link.
    @Test("throughput units never rescale")
    func pinnedThroughput() {
        #expect(Format.value(20000, unit: .bytesPerSecond) == "0.02 MB/s")
        #expect(Format.value(2_350_000, unit: .bytesPerSecond) == "2.35 MB/s")
        #expect(Format.value(5_000_000_000, unit: .bytesPerSecond) == "5000 MB/s")

        #expect(Format.value(940_000_000, unit: .bitsPerSecond) == "940 Mbit/s")
        #expect(Format.value(0, unit: .bitsPerSecond) == "0.00 Mbit/s")
    }

    /// Three significant figures keeps the readout near-constant in width,
    /// which matters because it sits in a fixed inset on the dial face.
    @Test("throughput readouts hold three significant figures")
    func throughputPrecision() {
        #expect(Format.throughput(2_350_000) == "2.35")
        #expect(Format.throughput(12_400_000) == "12.4")
        #expect(Format.throughput(245_000_000) == "245")
    }

    /// Memory is a level, not a throughput. It keeps auto-scaling, because
    /// "17179.87 MB" of RAM helps nobody.
    @Test("byte levels still scale to a readable unit")
    func levelsStillScale() {
        #expect(Format.value(17_179_869_184, unit: .bytes) == "17 GB")
        #expect(Format.value(1_500_000, unit: .bytes) == "1.5 MB")
    }

    /// The property the fixed field exists for: whatever the magnitude, the
    /// readout is the same width and the point is in the same column. A point
    /// that slides means `4.23` and `43.7` occupy the same pixels with different
    /// meanings, so you have to read the whole number to know which it is.
    @Test("the readout is a fixed field with an immovable decimal point")
    func fixedReadoutField() {
        let values = [0.0, 20000.0, 4_230_000.0, 43_700_000.0, 999_000_000.0, 5_012_660_000.0]
        let fields = values.map { Format.readout($0, unit: .bytesPerSecond) }

        #expect(fields == ["   0.00", "   0.02", "   4.23", "  43.70", " 999.00", "5012.66"])
        #expect(Set(fields.map(\.count)).count == 1, "the field changed width")
        #expect(
            Set(fields.map { $0.distance(from: $0.startIndex, to: $0.firstIndex(of: ".")!) })
                .count == 1,
            "the decimal point moved"
        )
    }

    /// Space-padded, not zero-padded: `0004.23` reads as a part number.
    @Test("the readout pads with blanks rather than zeros")
    func readoutPadding() {
        #expect(Format.readout(4_230_000, unit: .bitsPerSecond).hasPrefix("   "))
        #expect(!Format.readout(4_230_000, unit: .bitsPerSecond).hasPrefix("000"))
    }

    /// Four integer digits so an SSD at 5000 MB/s fits. The overflow pattern is
    /// there for completeness rather than because anything reaches it — and it
    /// keeps the field width, so the display cannot jump if it ever does.
    @Test("the readout field holds a fast SSD, and says so when it cannot")
    func readoutCeiling() {
        #expect(Format.readout(9_999_000_000, unit: .bytesPerSecond) == "9999.00")
        #expect(Format.readout(10_000_000_000, unit: .bytesPerSecond) == "----.--")
        // Would round up to 10000.00 and shift the point, so it counts as over.
        #expect(Format.readout(9_999_996_000, unit: .bytesPerSecond) == "----.--")
        #expect(
            Format.readout(10_000_000_000, unit: .bytesPerSecond).count
                == Format.readout(0, unit: .bytesPerSecond).count
        )
    }

    /// A tick is a landmark, not a measurement — the digits live in the
    /// readout below the needle.
    @Test("dial ticks are coarser than the readout")
    func tickLabels() {
        #expect(Format.tickLabel(0, unit: .bitsPerSecond) == "0")
        #expect(Format.tickLabel(5_000_000, unit: .bitsPerSecond) == "5")
        #expect(Format.tickLabel(10_000_000, unit: .bitsPerSecond) == "10")
        #expect(Format.tickLabel(500_000_000, unit: .bytesPerSecond) == "500")
    }
}
