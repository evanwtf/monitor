import Foundation

/// Anything that can be read on a clock.
///
/// A source declares its metrics up front so the UI can lay out charts before
/// any data arrives, and so the store can be prepared for series it has not
/// seen. `read` is called on the sampler's own queue and must not block for
/// long; a source that needs to talk to something slow should cache.
public protocol MetricSource: Sendable {
    /// Stable identifier, used in `monitorctl` arguments and in preferences.
    var id: String { get }

    /// Every metric this source can produce. May legitimately be empty on a
    /// machine that lacks the hardware.
    var descriptors: [MetricDescriptor] { get }

    /// Read once. Throw rather than return zeros: a failed read and an idle
    /// system must not look the same on a chart.
    func read(at timestamp: TimeInterval) throws -> SampleBatch

    /// The shortest interval at which this source can produce a *new* value.
    ///
    /// Not a preference and not a cost limit — a fact about the hardware
    /// underneath. Reading faster than this returns the previous value again,
    /// so the sampler skips the call entirely.
    ///
    /// Zero, the default, means "as fast as you like": a counter read from
    /// mach or IOKit is current whenever it is asked.
    var minimumInterval: TimeInterval { get }
}

public extension MetricSource {
    var minimumInterval: TimeInterval { 0 }
}

/// Why a source could not be used on this machine.
public enum MetricSourceError: Error, CustomStringConvertible {
    /// The API returned a failure. `code` is the raw `kern_return_t` or errno.
    case readFailed(String, code: Int32)
    /// The machine has no such hardware, or the OS does not expose it.
    case unavailable(String)
    /// The reading needs privileges the app does not have.
    case notPermitted(String)

    public var description: String {
        switch self {
        case let .readFailed(what, code): "could not read \(what) (code \(code))"
        case let .unavailable(what): "\(what) is not available on this machine"
        case let .notPermitted(what): "not permitted to read \(what)"
        }
    }
}

/// Turns monotonic counters into rates.
///
/// Sources for disk and network report totals since boot, which are useless to
/// chart directly. This holds the previous reading per metric and converts to a
/// per-second rate. It deliberately returns nil for the first reading of a
/// series — there is no rate yet, and reporting zero would draw a dip that did
/// not happen.
public struct RateTracker: Sendable {
    private var previous: [MetricID: (timestamp: TimeInterval, value: Double)] = [:]

    public init() {}

    public mutating func rate(
        for metric: MetricID,
        total: Double,
        at timestamp: TimeInterval
    ) -> Double? {
        defer { previous[metric] = (timestamp, total) }
        guard let last = previous[metric] else { return nil }
        let elapsed = timestamp - last.timestamp
        guard elapsed > 0 else { return nil }
        // A counter that went backwards means it wrapped or the device was
        // replaced. Neither is a rate worth guessing at, so skip the interval.
        guard total >= last.value else { return nil }
        return (total - last.value) / elapsed
    }
}
