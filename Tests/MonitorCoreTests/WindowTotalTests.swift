import Foundation
@testable import MonitorCore
import Testing

private let metric = MetricID("test.rate")

/// Samples at a fixed cadence, oldest first, ending at `end`.
private func steady(
    _ values: [Double], interval: TimeInterval = 0.5, end: TimeInterval = 1000
) -> [Sample] {
    let start = end - Double(values.count - 1) * interval
    return values.enumerated().map { offset, value in
        Sample(metric: metric, timestamp: start + Double(offset) * interval, value: value)
    }
}

@Suite("WindowTotal")
struct WindowTotalTests {
    @Test("A constant rate over a window totals rate times window")
    func constantRate() {
        // 10 MB/s for 60 s is 600 MB. The simplest claim this file makes, and
        // the one every other case is a variation on.
        let points = steady(Array(repeating: 10_000_000, count: 121), interval: 0.5)
        let result = WindowTotal.total(of: points, window: 60, maximumGap: 2)
        #expect(result?.value == 600_000_000)
        #expect(result?.covered == 60)
    }

    @Test("Differentiating a counter and integrating it back returns the delta")
    func roundTrip() {
        // The premise of the whole feature: a rate sample is the mean over the
        // gap before it, so summing rate times gap telescopes back to exactly
        // the counter delta. If this passes, the rest is formatting.
        //
        // Deliberately uneven, so the test cannot pass by multiplying by a
        // constant interval it happened to guess right.
        let deltas: [Double] = [0, 1400, 32, 900_000, 17, 0, 4, 250_000, 88, 1]
        var counter = 5_000_000_000.0
        var tracker = RateTracker()
        var points: [Sample] = []
        var timestamp = 1000.0
        for (index, delta) in deltas.enumerated() {
            counter += delta
            timestamp += index.isMultiple(of: 3) ? 0.5 : 0.75
            if let rate = tracker.rate(for: metric, total: counter, at: timestamp) {
                points.append(Sample(metric: metric, timestamp: timestamp, value: rate))
            }
        }

        // Two deltas drop out, for two different reasons. The first produced no
        // rate at all — there was no previous reading. The second produced the
        // oldest sample in the array, which has no predecessor to measure its
        // interval against, so its width is unknown and it contributes nothing.
        // Inventing a width for it would be a guess, and one sampling interval
        // out of a window of hundreds is not worth guessing for.
        let expected = deltas.dropFirst(2).reduce(0, +)
        let result = WindowTotal.total(of: points, window: 600, maximumGap: 10)
        #expect(abs((result?.value ?? 0) - expected) < 0.000001)
    }

    @Test("A gap straddling the window edge is clipped, not dropped or kept whole")
    func clipsAtTheEdge() {
        // Four samples 10 s apart, each reporting 100/s. A 25 s window ends at
        // the last one and reaches half way into a gap, so it covers two whole
        // intervals plus half of one: 100 * 25. The predecessor that measures
        // that half interval sits outside the window, which is why the sum
        // reads the whole array and filters only what it adds up.
        let points = steady([100, 100, 100, 100], interval: 10, end: 1000)
        let result = WindowTotal.total(of: points, window: 25, maximumGap: 60)
        #expect(result?.value == 2500)
        #expect(result?.covered == 25)
    }

    @Test("Uneven gaps weight each sample by the interval it measures")
    func unevenGaps() {
        // 1 s at 10/s, then 3 s at 100/s. A mean of the two values would say
        // 55 * 4 = 220; weighting by interval says 10 + 300 = 310.
        let points = [
            Sample(metric: metric, timestamp: 100, value: 0),
            Sample(metric: metric, timestamp: 101, value: 10),
            Sample(metric: metric, timestamp: 104, value: 100),
        ]
        let result = WindowTotal.total(of: points, window: 60, maximumGap: 10)
        #expect(result?.value == 310)
        // Four seconds of history, not sixty. The first sample opens the span
        // and contributes nothing, having no interval before it.
        #expect(result?.covered == 4)
    }

    @Test("A window longer than the history reports the span it really has")
    func shortHistory() {
        // Ten seconds after launch the buffer holds ten seconds. Reporting the
        // window it was asked for would put "2 min" under a number covering a
        // twelfth of that, which is the quiet kind of wrong: nobody checks it.
        let points = steady(Array(repeating: 1000, count: 21), interval: 0.5, end: 1000)
        let result = WindowTotal.total(of: points, window: 120, maximumGap: 2)
        #expect(result?.covered == 10)
        #expect(result?.value == 10000)
    }

    @Test("Fewer than two samples has no total at all")
    func needsTwoSamples() {
        // The same choice RateTracker makes on a first read. One sample is a
        // rate with no interval under it, and zero would draw as an idle
        // machine rather than as a missing answer.
        #expect(WindowTotal.total(of: [], window: 60, maximumGap: 2) == nil)
        #expect(WindowTotal.total(of: steady([500]), window: 60, maximumGap: 2) == nil)
    }

    @Test("An interval longer than maximumGap is clipped and comes off covered")
    func clampsLongGaps() {
        // A slept laptop, or a source that failed for a minute, leaves one
        // enormous interval. A rectangle drawn across it invents traffic that
        // never happened, so the sample gets maximumGap and the rest of the
        // span is not claimed as covered.
        let points = [
            Sample(metric: metric, timestamp: 100, value: 50),
            Sample(metric: metric, timestamp: 400, value: 50),
            Sample(metric: metric, timestamp: 400.5, value: 50),
        ]
        let result = WindowTotal.total(of: points, window: 600, maximumGap: 2)
        // 2 s of the 300 s gap, plus the half second after it.
        #expect(result?.value == 125)
        #expect(result?.covered == 2.5)
    }

    @Test("Samples out of order are totalled in time order")
    func sortsInput() {
        // The buffer hands them over oldest first, but a caller assembling a
        // card's series from several places need not, and a total that depends
        // on array order is a bug waiting for a refactor.
        let ordered = steady([0, 10, 20, 30], interval: 1)
        let shuffled = [ordered[2], ordered[0], ordered[3], ordered[1]]
        let expected = WindowTotal.total(of: ordered, window: 60, maximumGap: 10)
        #expect(WindowTotal.total(of: shuffled, window: 60, maximumGap: 10) == expected)
    }

    @Test("The window ends at the newest sample unless told otherwise")
    func explicitEnd() {
        // Same rule CSVExport follows: the right-hand edge of the chart, which
        // defaults to the newest sample the card holds.
        let points = steady([100, 100, 100], interval: 1, end: 1000)
        #expect(WindowTotal.total(of: points, window: 10, maximumGap: 10)?.value == 200)
        // An end before the last sample excludes it.
        let earlier = WindowTotal.total(of: points, window: 10, now: 999, maximumGap: 10)
        #expect(earlier?.value == 100)
    }
}

@Suite("MetricUnit accumulation")
struct MetricUnitAccumulationTests {
    @Test("Throughput accumulates into bytes, and network divides by eight")
    func throughput() {
        #expect(MetricUnit.bytesPerSecond.accumulation?.unit == .bytes)
        #expect(MetricUnit.bytesPerSecond.accumulation?.scale == 1)
        // A link is quoted in bits, a volume in bytes. The conversion lives
        // here so the header and anything downstream cannot disagree.
        #expect(MetricUnit.bitsPerSecond.accumulation?.unit == .bytes)
        #expect(MetricUnit.bitsPerSecond.accumulation?.scale == 1.0 / 8)
    }

    @Test("Operations accumulate into a count")
    func operations() {
        #expect(MetricUnit.operationsPerSecond.accumulation?.unit == .count)
    }

    @Test("A level does not add up")
    func levels() {
        // Adding temperatures produces degree-seconds, which is not a quantity
        // anybody wants under a chart of a CPU getting warm.
        for unit in [
            MetricUnit.fraction, .bytes, .count, .hertz, .celsius, .watts, .rpm, .seconds,
        ] {
            #expect(unit.accumulation == nil)
        }
    }
}

@Suite("Formatting a total")
struct TotalFormattingTests {
    @Test("A network total reads in bytes, not bits")
    func networkTotalsInBytes() {
        // 11.2 Gbit is 1.4 GB. Nobody has ever asked how many gigabits they
        // downloaded, and every cap and file size is quoted the other way.
        #expect(Format.total(11_200_000_000, unit: .bitsPerSecond) == "1.4 GB")
        // Disk is already bytes and passes straight through.
        #expect(Format.total(1_400_000_000, unit: .bytesPerSecond) == "1.4 GB")
    }

    @Test("An operations total reads as a count with SI suffixes")
    func operationTotals() {
        #expect(Format.total(1_234_567, unit: .operationsPerSecond) == "1.2 M")
        #expect(Format.total(340_000, unit: .operationsPerSecond) == "340 k")
        #expect(Format.total(847, unit: .operationsPerSecond) == "847")
    }

    @Test("A unit that does not accumulate has no total")
    func noTotal() {
        #expect(Format.total(42, unit: .celsius) == nil)
        #expect(Format.total(0.5, unit: .fraction) == nil)
        #expect(Format.widestTotal(unit: .watts) == nil)
    }

    @Test("A span reads the way the History picker words it")
    func spans() {
        // The label sits beside a segmented picker reading exactly these, and
        // two spellings of one duration on one screen reads as a fault.
        #expect(Format.span(60) == "1 min")
        #expect(Format.span(120) == "2 min")
        #expect(Format.span(300) == "5 min")
        #expect(Format.span(600) == "10 min")
    }

    @Test("A span short of a whole minute keeps its seconds")
    func partialSpans() {
        // A card 45 s after launch must say so rather than round itself up to
        // the window it was asked for.
        #expect(Format.span(45) == "45 s")
        #expect(Format.span(9.6) == "10 s")
        #expect(Format.span(90) == "90 s")
    }

    @Test("The reserved slot is at least as wide as the readings it holds")
    func reservationCoversRealValues() {
        // A floor, like widestValue: being wrong here costs a little jitter at
        // an extreme, never a clipped number. But it must cover the ordinary
        // range, which is where the eye actually reads it.
        let bytes = Format.widestTotal(unit: .bitsPerSecond) ?? ""
        for value in [1000.0, 8_000_000, 11_200_000_000, 800_000_000_000] {
            #expect(Format.total(value, unit: .bitsPerSecond)?.count ?? 0 <= bytes.count)
        }
        let counts = Format.widestTotal(unit: .operationsPerSecond) ?? ""
        for value in [1.0, 847, 340_000, 1_234_567] {
            #expect(Format.total(value, unit: .operationsPerSecond)?.count ?? 0 <= counts.count)
        }
    }
}
