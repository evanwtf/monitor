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

/// Which cards are a whole divided into slices.
///
/// No table here either. A metric declares its own `composition`, so a card can
/// be stacked when it draws two or more slices — and a source added later gets
/// it without this file being told it exists.
public enum ChartStack {
    /// The slices a card draws, in the order it draws them, or empty when it
    /// has nothing to stack.
    ///
    /// **Two or more.** A single band is an area chart with extra steps, and it
    /// says nothing a line does not.
    ///
    /// Everything else on the card keeps its line — an aggregate especially.
    /// Memory Used is app plus wired plus compressed, so stacking it would
    /// count those three twice; drawn as a line it lands exactly on top of the
    /// bands it sums, which reads as a check rather than a contradiction.
    public static func parts(of descriptors: [MetricDescriptor]) -> [MetricID] {
        let parts = descriptors.filter { $0.composition == .part }
        return parts.count >= 2 ? parts.map(\.id) : []
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

    /// Draw a card's slices as stacked bands rather than as lines from zero.
    ///
    /// Off by default, for the same reason mirroring is: a chart that changes
    /// shape under somebody on upgrade is worse than one they switch on.
    public var stacksParts: Bool

    /// Show how much moved over the window beside how fast it is moving.
    ///
    /// **On by default, unlike the two above**, and the argument for matching
    /// them lost on first contact: shipped off, the reaction to the finished
    /// feature was "I don't see it". Mirroring and stacking change what the
    /// picture *means*, so a reader who never asked for them deserves the chart
    /// they had; a total only adds a number beside one already there, and a
    /// number nobody can find is worth less than a header that reflows.
    public var showsTotals: Bool

    /// Turn the time labels on their side.
    ///
    /// Off by default: horizontal is easier to read, and on a card with room
    /// for them it is the right answer. Turned, a label costs its line height
    /// instead of its width, so a narrow card fits five times where it fitted
    /// two — which is the trade somebody running a dense panel wants and
    /// somebody running three big cards does not.
    public var rotatesTimeLabels: Bool

    public init(
        mirrorsPairs: Bool = false,
        stacksParts: Bool = false,
        showsTotals: Bool = true,
        rotatesTimeLabels: Bool = false
    ) {
        self.mirrorsPairs = mirrorsPairs
        self.stacksParts = stacksParts
        self.showsTotals = showsTotals
        self.rotatesTimeLabels = rotatesTimeLabels
    }

    public static let `default` = ChartPreferences()

    /// The pair this card should mirror, given the setting: nil when mirroring
    /// is off, and nil when the card is not a pair.
    public func mirror(for descriptors: [MetricDescriptor]) -> MetricPair? {
        guard mirrorsPairs else { return nil }
        return ChartMirror.pair(for: descriptors)
    }

    /// The slices this card should stack, given the setting: empty when
    /// stacking is off, and empty when the card has nothing to stack.
    public func stack(for descriptors: [MetricDescriptor]) -> [MetricID] {
        guard stacksParts else { return [] }
        return ChartStack.parts(of: descriptors)
    }

    private enum CodingKeys: String, CodingKey {
        case mirrorsPairs
        case stacksParts
        case showsTotals
        case rotatesTimeLabels
    }

    /// `decodeIfPresent`, so a value written before a setting existed still
    /// decodes rather than resetting the whole struct to its defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mirrors = try container.decodeIfPresent(Bool.self, forKey: .mirrorsPairs)
        let stacks = try container.decodeIfPresent(Bool.self, forKey: .stacksParts)
        let totals = try container.decodeIfPresent(Bool.self, forKey: .showsTotals)
        let rotates = try container.decodeIfPresent(Bool.self, forKey: .rotatesTimeLabels)
        self.init(
            mirrorsPairs: mirrors ?? ChartPreferences.default.mirrorsPairs,
            stacksParts: stacks ?? ChartPreferences.default.stacksParts,
            showsTotals: totals ?? ChartPreferences.default.showsTotals,
            rotatesTimeLabels: rotates ?? ChartPreferences.default.rotatesTimeLabels
        )
    }
}
