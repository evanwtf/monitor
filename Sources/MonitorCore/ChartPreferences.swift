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
/// No table of metric ids here. A metric declares its own `direction` in
/// `MetricDescriptor`, so a card is a pair when it draws exactly one inbound
/// series and one outbound one — and a source added later gets mirroring
/// without this file being told it exists.
public enum ChartMirror {
    /// The pair a card draws, or nil if it does not draw exactly one.
    ///
    /// **Both halves or neither.** A card showing only the download half would
    /// mirror into a single trace hanging below an empty top half, which reads
    /// as a bug rather than as a choice. Switch one direction off in
    /// preferences and the card goes back to drawing upward from zero.
    ///
    /// Inbound above outbound: the first is the one that arrives, and download
    /// above upload is how every meter of this kind has drawn it since modem
    /// lights.
    public static func pair(for descriptors: [MetricDescriptor]) -> MetricPair? {
        guard descriptors.count == 2 else { return nil }
        let inbound = descriptors.filter { $0.direction == .inbound }
        let outbound = descriptors.filter { $0.direction == .outbound }
        guard inbound.count == 1, let up = inbound.first,
              outbound.count == 1, let down = outbound.first
        else { return nil }
        return MetricPair(up: up.id, down: down.id)
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
    public func mirror(for descriptors: [MetricDescriptor]) -> MetricPair? {
        guard mirrorsPairs else { return nil }
        return ChartMirror.pair(for: descriptors)
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
