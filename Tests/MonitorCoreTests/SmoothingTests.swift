import Foundation
@testable import MonitorCore
import Testing

private func samples(_ values: [(TimeInterval, Double)]) -> [Sample] {
    values.map { Sample(metric: MetricID("m"), timestamp: $0.0, value: $0.1) }
}

/// One sample a second, starting at zero.
private func everySecond(_ values: [Double]) -> [Sample] {
    samples(values.enumerated().map { (TimeInterval($0.offset), $0.element) })
}

@Suite("Rolling")
struct RollingTests {
    @Test("No samples, no points")
    func empty() {
        #expect(Rolling.points([], window: 5, maximumGap: 10).isEmpty)
    }

    @Test("One point per sample, at the sample's own timestamp")
    func onePerSample() {
        let result = Rolling.points(everySecond([1, 2, 3, 4]), window: 2, maximumGap: 10)
        #expect(result.map(\.timestamp) == [0, 1, 2, 3])
    }

    @Test("A lone sample is its own mean, median, minimum and maximum")
    func single() {
        let result = Rolling.points(everySecond([7]), window: 5, maximumGap: 10)
        #expect(result == [
            RollingPoint(timestamp: 0, mean: 7, median: 7, minimum: 7, maximum: 7),
        ])
    }

    @Test("The window is trailing and open at its left edge")
    func trailingWindow() {
        // At t = 3 a two-second window is (1, 3]: the samples at 2 and 3. The
        // one at 1 sits exactly on the edge and is out, or a 5 s window at
        // 0.5 s would hold eleven samples rather than ten.
        let result = Rolling.points(everySecond([0, 10, 20, 30]), window: 2, maximumGap: 10)
        #expect(result.map(\.mean) == [0, 5, 15, 25])
    }

    @Test("The start of the series averages what there is")
    func warmUp() {
        // No window reaches back before the first sample. The first point is
        // the first sample, not a mean diluted by zeros that were never read.
        let result = Rolling.points(everySecond([4, 8, 12]), window: 60, maximumGap: 10)
        #expect(result.map(\.mean) == [4, 6, 8])
    }

    @Test("The median drops a lone spike that the mean smears")
    func medianIgnoresSpike() {
        let result = Rolling.points(
            everySecond([1, 1, 100, 1, 1]), window: 5, maximumGap: 10
        )
        #expect(result.last?.median == 1)
        #expect(result.last?.mean == 20.8)
    }

    @Test("An even window's median is the mean of its middle two")
    func evenMedian() {
        let result = Rolling.points(everySecond([1, 2, 3, 10]), window: 4, maximumGap: 10)
        #expect(result.last?.median == 2.5)
    }

    @Test("The band is the window's minimum and maximum")
    func band() {
        let result = Rolling.points(
            everySecond([5, 0, 9, 3, 4]), window: 3, maximumGap: 10
        )
        // (1, 4]: 9, 3, 4.
        #expect(result.last?.minimum == 3)
        #expect(result.last?.maximum == 9)
        // A spike stays at full height in the band, which is its reason to
        // exist beside the mean.
        #expect(result[2].maximum == 9)
    }

    @Test("A window never reaches across a gap")
    func gapResets() {
        // A laptop asleep for ninety seconds. The first reading after it must
        // not be blended with the last reading before it.
        let result = Rolling.points(
            samples([(0, 100), (1, 100), (2, 100), (92, 0), (93, 2)]),
            window: 300, maximumGap: 4
        )
        #expect(result[3].mean == 0)
        #expect(result[3].maximum == 0)
        #expect(result[4].mean == 1)
    }

    @Test("A gap no wider than the limit is not a gap")
    func gapAtLimit() {
        let result = Rolling.points(
            samples([(0, 10), (4, 20)]), window: 60, maximumGap: 4
        )
        #expect(result.last?.mean == 15)
    }

    @Test("Order in does not change the answer")
    func unsorted() {
        let sorted = Rolling.points(everySecond([3, 1, 4, 1, 5]), window: 3, maximumGap: 10)
        let shuffled = Rolling.points(
            everySecond([3, 1, 4, 1, 5]).reversed(), window: 3, maximumGap: 10
        )
        #expect(sorted == shuffled)
    }

    /// Why the mean is the one mode a stacked card may use. The bands of a
    /// stacked card must still add up to the aggregate drawn over them, and
    /// that holds after smoothing only when the smoothing is linear.
    @Test("The mean of the slices sums to the mean of the whole")
    func meanIsLinear() {
        let app = [3.0, 9, 1, 7, 2, 8]
        let wired = [5.0, 1, 6, 2, 9, 4]
        let used = zip(app, wired).map(+)
        let parts = [app, wired].map {
            Rolling.points(everySecond($0), window: 3, maximumGap: 10).map(\.mean)
        }
        let whole = Rolling.points(everySecond(used), window: 3, maximumGap: 10)
        for index in used.indices {
            #expect(abs(parts[0][index] + parts[1][index] - whole[index].mean) < 1e-9)
        }
    }

    /// And why the median is not: here the slices' medians sum to 8, the whole
    /// has a median of 10, and a Used line drawn from the whole would float
    /// above the stack it is supposed to sit on.
    @Test("The median of the slices does not sum to the median of the whole")
    func medianIsNotLinear() {
        let app = [0.0, 10, 0]
        let wired = [8.0, 0, 10]
        let used = zip(app, wired).map(+)
        let appMedian = Rolling.points(everySecond(app), window: 3, maximumGap: 10)
        let wiredMedian = Rolling.points(everySecond(wired), window: 3, maximumGap: 10)
        let wholeMedian = Rolling.points(everySecond(used), window: 3, maximumGap: 10)
        let sum = (appMedian.last?.median ?? 0) + (wiredMedian.last?.median ?? 0)
        #expect(sum != wholeMedian.last?.median)
    }
}

@Suite("Smoothing")
struct SmoothingTests {
    @Test("Each method reads its own statistic")
    func values() {
        let point = RollingPoint(timestamp: 0, mean: 1, median: 2, minimum: 0, maximum: 3)
        #expect(Smoothing(method: .mean, window: 5).line(point) == 1)
        #expect(Smoothing(method: .median, window: 5).line(point) == 2)
        // The band's line is its mean, so the band includes the average.
        #expect(Smoothing(method: .band, window: 5).line(point) == 1)
    }

    @Test("Only the band draws a band")
    func drawsBand() {
        #expect(Smoothing(method: .band, window: 5).drawsBand)
        #expect(!Smoothing(method: .mean, window: 5).drawsBand)
        #expect(!Smoothing(method: .median, window: 5).drawsBand)
    }

    @Test("Only the mean may smooth a stacked card")
    func stackable() {
        #expect(SmoothingMethod.mean.isStackable)
        #expect(!SmoothingMethod.median.isStackable)
        #expect(!SmoothingMethod.band.isStackable)
    }

    @Test("The label says which method and how long")
    func label() {
        #expect(Format.smoothing(Smoothing(method: .mean, window: 5)) == "avg 5 s")
        #expect(Format.smoothing(Smoothing(method: .median, window: 15)) == "median 15 s")
        #expect(Format.smoothing(Smoothing(method: .band, window: 60)) == "min–max 1 min")
    }

    @Test("Windows are whole seconds, shortest first")
    func windows() {
        #expect(Smoothing.windows == [5, 15, 60])
    }

    @Test("Switching smoothing on picks a window that is on offer")
    func defaultWindow() {
        // Otherwise the Window section would show no tick at all.
        #expect(Smoothing.windows.contains(Smoothing.defaultWindow))
    }
}
