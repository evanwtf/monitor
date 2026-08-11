import Foundation

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
///  - **Snap to 1, 2 or 5 times a power of ten.** An arbitrary full scale means
///    tick labels like 3.7 GB/s, which nobody can read at a glance. Snapping
///    means the ticks are always round numbers.
///  - **Rise immediately, fall slowly.** A needle whose dial rescales the
///    instant traffic drops is unreadable — the needle appears to move when the
///    value did not. Full scale jumps up at once when the value exceeds it, and
///    only steps down after the peak has stayed low for `decayInterval`.
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

    public private(set) var fullScale: Double
    /// Highest value seen in the current decay window — what the redline marks.
    public private(set) var peak: Double = 0
    /// Start of the current decay window.
    private var windowStart: TimeInterval?

    public init(floor: Double, decayInterval: TimeInterval = 15) {
        self.floor = floor
        self.decayInterval = decayInterval
        fullScale = GaugeScale.snap(floor)
    }

    /// Feed a reading. Returns the current full scale.
    @discardableResult
    public mutating func update(value: Double, at timestamp: TimeInterval) -> Double {
        if windowStart == nil { windowStart = timestamp }
        peak = max(peak, value)

        if value > fullScale {
            fullScale = GaugeScale.snap(max(value, floor))
            return fullScale
        }

        // The peak is over a trailing window, not since the app launched. An
        // all-time peak never decays, so one 900 MB/s spike at breakfast would
        // pin the dial at 1 GB/s for the rest of the day and every reading
        // after it would sit uselessly against the stop.
        guard let start = windowStart, timestamp - start >= decayInterval else {
            return fullScale
        }
        let target = GaugeScale.snap(max(peak, floor))
        if target < fullScale { fullScale = target }
        // Start the next window from the reading that just arrived.
        peak = value
        windowStart = timestamp
        return fullScale
    }

    /// Needle position, 0...1.
    public func deflection(for value: Double) -> Double {
        guard fullScale > 0 else { return 0 }
        return min(1, max(0, value / fullScale))
    }

    /// Rounds up to the next 1, 2 or 5 times a power of ten.
    public static func snap(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = log10(value).rounded(.down)
        let magnitude = pow(10, exponent)
        let normalized = value / magnitude
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
    }
}
