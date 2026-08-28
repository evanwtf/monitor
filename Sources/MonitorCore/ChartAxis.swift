import Foundation

/// Where the time labels go along the bottom of a chart.
///
/// Here rather than in the view because it is arithmetic, and arithmetic that
/// has been wrong on screen three times.
///
/// **A tick is an instant, not a position.** 10:42:00 belongs at 10:42:00, and
/// as the window scrolls it must travel left and eventually off the edge with
/// its label unchanged. Ticks placed at fixed fractions of the window do the
/// opposite: the gridline stands still and the time under it counts up in real
/// time, which is a clock, not an axis.
///
/// Swift Charts will place instants itself with `.automatic`, and that was the
/// first version. It treats `desiredCount` as a hint and picks its own
/// boundaries, so on a narrow card the labels crowded into each other and ran
/// off the right edge. Choosing the interval here keeps both properties: real
/// instants, and never more of them than fit.
public enum ChartAxis {
    /// The intervals worth labelling, in seconds, finest first. Each divides a
    /// minute or is a whole number of minutes, so a tick lands on a time
    /// somebody would write down.
    static let strides: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    /// Two labels is what the axis wants; five is as dense as it should ever
    /// get, because past that they are closer together than the eye needs on a
    /// chart this size. Neither is a guarantee — see `marks`.
    static let fewest = 2
    static let most = 5

    /// The widest label each format produces, **measured** rather than
    /// estimated: SF Rounded at `Theme.Layout.timeLabel`, worst case
    /// "18:52:30" and "18:52".
    ///
    /// The two differ by a third, and that is the fact the arithmetic used to
    /// miss. Budgeting every stride at the with-seconds width made the coarse
    /// strides — the ones with the narrow labels, the ones a cramped card
    /// wants — look as expensive as the fine ones, so the axis never reached
    /// for them.
    static let secondsLabelWidth = 32.0
    static let minuteLabelWidth = 20.0
    /// Turned on its side a label costs its line height instead, whatever it
    /// says.
    static let rotatedLabelWidth = 10.0
    /// The clear space between two labels. Below about this they stop reading
    /// as two numbers and start reading as one long one.
    static let gutter = 8.0

    /// Points of plot one label needs, including the gutter after it.
    public static func spacing(showsSeconds: Bool, rotated: Bool) -> Double {
        let label = rotated
            ? rotatedLabelWidth
            : (showsSeconds ? secondsLabelWidth : minuteLabelWidth)
        return label + gutter
    }

    /// How many labels of one format fit across a plot.
    ///
    /// `width` is the **plot**, not the card and not the chart. The y-axis and
    /// its labels are outside it and they are much wider on "20 MB/s" than on
    /// "0%" — and the cards with the longest numbers are the ones whose plots
    /// are narrowest. This used to take the chart's width less a flat 50-point
    /// allowance, which is right for one card and optimistic for exactly the
    /// cards that could least afford optimism.
    public static func maximumTicks(
        width: Double, showsSeconds: Bool = true, rotated: Bool = false
    ) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let fit = Int(width / spacing(showsSeconds: showsSeconds, rotated: rotated))
        return max(1, min(most, fit))
    }

    /// The most labels a stride can produce in a window of this length.
    ///
    /// A window of length L holds either floor(L / stride) boundaries or one
    /// more, depending on where it happens to sit. The axis has to survive the
    /// worse of those, since the window slides.
    static func worstCaseCount(usable: TimeInterval, stride: TimeInterval) -> Int {
        Int((usable / stride).rounded(.down)) + 1
    }

    /// Ticks are held this far in from each edge of the window.
    ///
    /// A label is centred on its tick, so one sitting hard against an edge is
    /// half cut off — which is what truncated the last label to "10:34…". A
    /// tick inside the band is dropped rather than moved: moving it would put
    /// it somewhere that is not the time it claims.
    static let edgeFraction = 0.06

    /// The labelled instants for one window, and how far apart they are.
    public struct Marks: Equatable, Sendable {
        public let times: [TimeInterval]
        public let stride: TimeInterval
    }

    /// The interval to label at: the finest one whose own labels fit the plot.
    ///
    /// Chosen from the *length* of the window, not from where it happens to
    /// sit. The ticks themselves are absolute instants, so the exact count
    /// drifts by one as the window slides — but the interval must not, or the
    /// axis restyles itself every few seconds. Picking the interval by counting
    /// the ticks it actually produced was an earlier version, and on a narrow
    /// ten-minute card it flipped between 300 s and 120 s as the window moved,
    /// so the labels jumped between two and five.
    ///
    /// **Fitting wins over the two-label floor**, which reverses the rule this
    /// used to follow. That rule said slightly tight labels beat a bare axis,
    /// and it was right about "slightly tight" and wrong about what the
    /// arithmetic produced: on a 160-point plot the axis drew four labels 32
    /// points wide with their centres 40 apart, and at the narrowest card they
    /// overlapped outright. Labels that collide are not slightly tight — they
    /// are unreadable, and worse than the sparse axis the old rule was
    /// avoiding. Two labels are still what it reaches for, because the walk
    /// goes finest first and a finer stride is a denser axis; a window that
    /// cannot show two without them touching now shows one rather than two on
    /// top of each other. **Turning the labels sideways is how to have both**,
    /// which is what the setting is for.
    ///
    /// Each stride is costed at the width of *its own* labels. A stride of a
    /// minute or more shows no seconds, so it needs a third less room than a
    /// finer one — which is exactly why a cramped card can still carry a
    /// readable axis.
    public static func marks(
        from start: TimeInterval,
        to end: TimeInterval,
        plotWidth: Double,
        rotated: Bool = false
    ) -> Marks {
        guard end > start else { return Marks(times: [], stride: strides[0]) }
        let usable = (end - start) * (1 - 2 * edgeFraction)
        let width = plotWidth.isFinite ? max(0, plotWidth) : 0

        // Finest first, so the first that fits is the densest that fits.
        let stride = strides.first { candidate in
            let count = worstCaseCount(usable: usable, stride: candidate)
            guard count <= most else { return false }
            let each = spacing(
                showsSeconds: showsSeconds(stride: candidate), rotated: rotated
            )
            return Double(count) * each <= width
        }
            // Nothing fits: the coarsest interval there is, which is also the
            // one that asks for the least room.
            ?? strides[strides.count - 1]

        return Marks(times: times(from: start, to: end, stride: stride), stride: stride)
    }

    /// Every multiple of `stride` inside the window, less the edge bands.
    ///
    /// Multiples counted from the epoch. Time zone offsets are whole minutes,
    /// so a multiple of 30 s is on a local half-minute too.
    public static func times(
        from start: TimeInterval, to end: TimeInterval, stride: TimeInterval
    ) -> [TimeInterval] {
        guard stride > 0, end > start else { return [] }
        let band = (end - start) * edgeFraction
        let last = end - band
        var tick = ((start + band) / stride).rounded(.up) * stride
        var times: [TimeInterval] = []
        while tick <= last {
            times.append(tick)
            tick += stride
        }
        return times
    }

    /// Whether the labels need seconds to stay distinct. An interval under a
    /// minute lands two labels inside the same minute.
    public static func showsSeconds(stride: TimeInterval) -> Bool { stride < 60 }
}
