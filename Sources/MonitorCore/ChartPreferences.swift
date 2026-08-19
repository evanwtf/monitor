import Foundation

/// Two metrics that are opposite directions of one thing.
///
/// Network in and out, disk read and written. Not any two metrics that share a
/// card: temperature sensors share one, and neither of them is the opposite of
/// the other.
public struct MetricPair: Equatable, Sendable {
    /// Drawn above the baseline.
    public let up: MetricID
    /// Drawn below it.
    public let down: MetricID

    public init(up: MetricID, down: MetricID) {
        self.up = up
        self.down = down
    }
}

/// Which cards are two directions of one thing, and which way round.
///
/// A table here rather than a field on `MetricDescriptor`. A descriptor says
/// what a metric *is* — name, group, unit, kind — and it is declared by the
/// source that reads it. "This one points down" is a statement about a picture,
/// and a disk reader has no business making it. Keeping the table separate also
/// means a source can be added without deciding whether it has an opposite.
///
/// In and out rather than out and in, read above written: the first is the one
/// that arrives, and download above upload is the way every meter of this kind
/// has drawn it since modem lights.
public enum ChartMirror {
    public static let pairs = [
        MetricPair(up: MetricID("net.bits.in"), down: MetricID("net.bits.out")),
        MetricPair(up: MetricID("disk.bytes.read"), down: MetricID("disk.bytes.written")),
    ]

    /// The pair a card draws, or nil if it does not draw exactly one.
    ///
    /// **Both halves or neither.** A card showing only the download half would
    /// mirror into a single trace hanging below an empty top half, which reads
    /// as a bug rather than as a choice. Switch one direction off in
    /// preferences and the card goes back to drawing upward from zero.
    public static func pair(for metrics: [MetricID]) -> MetricPair? {
        let drawn = Set(metrics)
        guard drawn.count == 2 else { return nil }
        return pairs.first { drawn == [$0.up, $0.down] }
    }
}

/// How the charts are drawn, as opposed to which ones there are.
///
/// Its own type beside `LayoutPreferences` rather than a field on it, because
/// the two answer different questions. `LayoutPreferences` is *which cards
/// exist*; this is *how one of them is drawn*. They are chosen on different
/// tabs and stored under different keys, so a value a later version writes
/// costs one of them and not both.
public struct ChartPreferences: Codable, Equatable, Sendable {
    /// Draw a paired card as one trace above the baseline and the other below.
    ///
    /// Off by default. Mirroring is the clearer way to read throughput, but a
    /// chart that changes shape under somebody on upgrade is worse than one
    /// they have to switch on.
    public var mirrorsPairs: Bool

    public init(mirrorsPairs: Bool = false) {
        self.mirrorsPairs = mirrorsPairs
    }

    public static let `default` = ChartPreferences()

    /// The pair this card should mirror, given the setting: nil when mirroring
    /// is off, and nil when the card is not a pair.
    public func mirror(for metrics: [MetricID]) -> MetricPair? {
        guard mirrorsPairs else { return nil }
        return ChartMirror.pair(for: metrics)
    }

    private enum CodingKeys: String, CodingKey {
        case mirrorsPairs
    }

    /// `decodeIfPresent`, so a value written before a setting existed still
    /// decodes rather than resetting the whole struct to its defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent(Bool.self, forKey: .mirrorsPairs)
        self.init(mirrorsPairs: stored ?? ChartPreferences.default.mirrorsPairs)
    }
}
