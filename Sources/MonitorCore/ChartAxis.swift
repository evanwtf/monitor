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

    /// Points of card per label, measured off the narrowest column the grid
    /// makes. Two is the fewest that says anything; past five they are closer
    /// together than the eye needs on a chart this size.
    static let spacing = 78.0
    static let fewest = 2
    static let most = 5

    /// The y-axis and its labels, which the measured width includes and the
    /// time labels cannot use.
    static let axisAllowance = 50.0

    /// How many labels this card has room for.
    public static func maximumTicks(width: Double) -> Int {
        guard width.isFinite else { return fewest }
        return max(fewest, min(most, Int((width - axisAllowance) / spacing)))
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

    /// The interval to label at: as many labels as the card has room for, and
    /// never fewer than two.
    ///
    /// Chosen from the *length* of the window, not from where it happens to
    /// sit. The ticks themselves are absolute instants, so the exact count
    /// drifts by one as the window slides — but the interval must not, or the
    /// axis restyles itself every few seconds. Picking the interval by counting
    /// the ticks it actually produced was the previous version, and on a narrow
    /// ten-minute card it flipped between 300 s and 120 s as the window moved,
    /// so the labels jumped between two and five.
    ///
    /// Two rules, in this order:
    ///
    /// 1. **Never fewer than two labels.** One lonely label says nothing about
    ///    the span you are looking at.
    /// 2. **Never more than the card has room for**, where that is compatible
    ///    with the first. On a narrow card showing ten minutes it is not, and
    ///    slightly tight labels beat a bare axis.
    public static func marks(
        from start: TimeInterval, to end: TimeInterval, maximumTicks: Int
    ) -> Marks {
        guard end > start else { return Marks(times: [], stride: strides[0]) }
        let usable = (end - start) * (1 - 2 * edgeFraction)

        // The coarsest interval that still fits `fewest` of itself in the
        // window, whatever the window's phase.
        let guaranteeing = strides.last { (usable / $0).rounded(.down) >= Double(fewest) }
            ?? strides[0]
        // The finest interval that cannot produce more labels than fit. A
        // window of length L holds either floor(L / stride) boundaries or one
        // more, depending on its phase, so the worst case is that floor plus
        // one.
        let capping = strides.first {
            (usable / $0).rounded(.down) + 1 <= Double(maximumTicks)
        } ?? strides[strides.count - 1]

        // The finer of the two. Finer than `guaranteeing` still guarantees two,
        // so this respects the room whenever the room allows two, and gives up
        // on the room rather than on the two when it does not.
        let stride = Swift.min(guaranteeing, capping)
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
