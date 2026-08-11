import Foundation

/// The set of values a dial's full scale is allowed to take.
///
/// Two ladders, because the two situations are genuinely different. When the
/// range is unknown, 1-2-5 keeps the needle in a useful part of the sweep — a
/// dial fixed at decades spends most of its life below a fifth of full scale.
/// When the reader already has the ladder in their head, which for MB/s and
/// Mbit/s they do, decades are worth the lost resolution: full scale becomes
/// predictable, so a glance at the needle is enough and the number underneath
/// is confirmation rather than a prerequisite.
public enum ScaleLadder: Sendable {
    /// 1, 2 or 5 times a power of ten: … 10, 20, 50, 100, 200, 500 …
    case oneTwoFive
    /// Powers of ten only: … 10, 100, 1000 …
    case decade

    /// The smallest step on this ladder that is at least `value`.
    public func snap(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let (magnitude, normalized) = ScaleLadder.decompose(value)
        switch self {
        case .oneTwoFive:
            let step: Double =
                if normalized <= 1 {
                    1
                } else if normalized <= 2 {
                    2
                } else if normalized <= 5 {
                    5
                } else {
                    10
                }
            return step * magnitude
        case .decade:
            // `normalized` is in 1..<10, so anything above an exact power of
            // ten belongs on the next decade up.
            return normalized <= 1 ? magnitude : magnitude * 10
        }
    }

    /// The largest step on this ladder that is strictly below `value`.
    ///
    /// Defined whether or not `value` is itself on the ladder, so it answers
    /// "what would the next scale down be" for any dial.
    public func step(below value: Double) -> Double? {
        guard value > 0, value.isFinite else { return nil }
        let (magnitude, normalized) = ScaleLadder.decompose(value)
        switch self {
        case .oneTwoFive:
            if normalized > 5 { return 5 * magnitude }
            if normalized > 2 { return 2 * magnitude }
            if normalized > 1 { return magnitude }
            // Exactly on a power of ten, so the rung below is in the decade
            // underneath: 100 → 50.
            return magnitude / 2
        case .decade:
            return normalized > 1 ? magnitude : magnitude / 10
        }
    }

    /// Splits a positive value into a power of ten and a mantissa in 1..<10.
    ///
    /// `log10` is not exact for every power of ten on every platform, and a
    /// mantissa that comes back as 9.999999 instead of 1 would put a scale a
    /// whole decade wrong. The two corrections below cost nothing and remove
    /// the class of bug entirely.
    private static func decompose(_ value: Double) -> (magnitude: Double, normalized: Double) {
        var magnitude = pow(10, log10(value).rounded(.down))
        if value / magnitude >= 10 { magnitude *= 10 }
        if value / magnitude < 1 { magnitude /= 10 }
        return (magnitude, value / magnitude)
    }
}

/// Picks the full-scale value for an analog gauge.
///
/// A benchmark gauge has it easy: the tester knows a disk tops out around
/// 3 GB/s and pins the dial there. A monitor does not. Disk write rate is
/// 2 MB/s while a mail client syncs and 6 GB/s during a restore, and a dial
/// fixed for one is useless for the other.
///
/// So full scale auto-ranges, with two rules that make the needle readable
/// rather than merely correct:
///
///  - **Snap to a ladder.** An arbitrary full scale means tick labels like
///    3.7 GB/s, which nobody can read at a glance. Snapping means the ticks are
///    always round numbers. Which ladder is a per-gauge choice — see
///    `ScaleLadder`.
///  - **Rise immediately, fall slowly.** A needle whose dial rescales the
///    instant traffic drops is unreadable — the needle appears to move when the
///    value did not. Full scale jumps up at once when the value exceeds it, and
///    only steps down once the value has stayed clear of the next scale down
///    for a continuous `decayInterval`.
///
/// This is a value type in MonitorCore, not a view, so the behaviour is
/// testable without rendering anything.
public struct GaugeScale: Sendable {
    /// Never scale below this, so an idle gauge does not sit at full deflection
    /// on 3 bytes a second.
    public let floor: Double
    /// How long the peak must stay below the next scale down before the dial
    /// rescales.
    public let decayInterval: TimeInterval
    /// Which values full scale is allowed to take.
    public let ladder: ScaleLadder
    /// How far below the next scale down the peak must sit before the dial
    /// takes it — 0.9 means "below 9 on the way down from 10".
    ///
    /// This is hysteresis, and without it a workload that happens to sit at
    /// exactly full scale rescales the dial every window, forever. The needle
    /// then moves constantly while the value does not, which is the one thing a
    /// gauge must never do.
    public let releaseFraction: Double

    public private(set) var fullScale: Double
    /// The high-water mark that explains the current scale: the highest reading
    /// since full scale last changed. Drawn as the memory mark on the dial, so
    /// a dial sitting on a scale nothing currently needs still shows why.
    public private(set) var peak: Double = 0
    /// When the value last dropped below the release threshold, or nil if it is
    /// above it now. This is what the decay measures against.
    private var quietSince: TimeInterval?
    /// Highest reading since `quietSince`, which decides how far the scale
    /// falls once the quiet period is up.
    private var quietPeak: Double = 0

    public init(
        floor: Double,
        decayInterval: TimeInterval = 15,
        ladder: ScaleLadder = .oneTwoFive,
        releaseFraction: Double = 0.9
    ) {
        self.floor = floor
        self.decayInterval = decayInterval
        self.ladder = ladder
        self.releaseFraction = releaseFraction
        fullScale = ladder.snap(floor)
    }

    /// Feed a reading. Returns the current full scale.
    @discardableResult
    public mutating func update(value: Double, at timestamp: TimeInterval) -> Double {
        if value > fullScale {
            fullScale = ladder.snap(max(value, floor))
            // A new scale gets a fresh high-water mark, and the clock on
            // coming back down starts from the spike that caused it.
            peak = value
            quietSince = nil
            quietPeak = 0
            return fullScale
        }

        peak = max(peak, value)

        // Nothing to fall to: already on the bottom rung.
        guard let lower = ladder.step(below: fullScale), lower >= floor else {
            quietSince = nil
            return fullScale
        }

        // The decay measures how long the value has been *continuously* below
        // the threshold, not the peak of a fixed window. A tumbling window
        // cannot express this: the window that contains the spike also contains
        // the evidence against coming down, so the dial would need two full
        // windows — twenty minutes for a ten-minute rule — before it moved.
        let threshold = lower * releaseFraction
        guard value < threshold else {
            quietSince = nil
            quietPeak = 0
            return fullScale
        }

        if quietSince == nil { quietSince = timestamp }
        quietPeak = max(quietPeak, value)

        guard let since = quietSince, timestamp - since >= decayInterval else {
            return fullScale
        }
        // Descend as far as the quiet period justifies rather than one rung at
        // a time. Ten quiet minutes should take a dial from 1000 back to 10,
        // not start a half-hour walk down during which every reading is
        // squashed against the bottom of the sweep.
        while let next = ladder.step(below: fullScale),
              next >= floor,
              quietPeak < next * releaseFraction
        {
            fullScale = next
        }
        peak = quietPeak
        quietSince = timestamp
        quietPeak = value
        return fullScale
    }

    /// Needle position, 0...1.
    public func deflection(for value: Double) -> Double {
        guard fullScale > 0 else { return 0 }
        return min(1, max(0, value / fullScale))
    }

    /// Rounds up to the next 1, 2 or 5 times a power of ten.
    public static func snap(_ value: Double) -> Double {
        ScaleLadder.oneTwoFive.snap(value)
    }
}
