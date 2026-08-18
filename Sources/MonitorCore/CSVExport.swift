import Foundation

/// Turns what a card is showing into a table somebody can paste into a
/// spreadsheet.
///
/// In `MonitorCore` rather than beside the view, for the same reason the
/// preference models are: the interesting part is the row alignment and the
/// choice of units, and neither needs a window to test.
///
/// Two rules shape it. **Copy what the picture showed** — the buffer holds ten
/// minutes and a card usually shows one or two, so the export is cut to the
/// same window rather than handed over whole. And **copy what was stored, not
/// what was drawn** — the panel pins disk to MB/s and network to Mbit/s
/// because a unit under a needle must not move while you read it, but a
/// spreadsheet has no needle and a divided number is a number somebody has to
/// undo. The header names the unit so the two can never be confused.
public enum CSVExport {
    /// One column per series, one row per timestamp.
    ///
    /// - Parameters:
    ///   - series: the card's series, in the order it draws them.
    ///   - window: seconds of history the card is showing.
    ///   - now: the right-hand edge of the chart. Defaults to the newest
    ///     sample, which is what the card itself uses.
    ///   - timeZone: the zone the timestamps are written in.
    public static func text(
        for series: [(descriptor: MetricDescriptor, points: [Sample])],
        window: TimeInterval,
        now: TimeInterval? = nil,
        timeZone: TimeZone = .current
    ) -> String {
        let end = now ?? series.compactMap { $0.points.last?.timestamp }.max()
            ?? Date().timeIntervalSince1970
        let start = end - window

        // One dictionary per series rather than a search per cell: a ten-minute
        // buffer at two samples a second is 1200 points, and a card can carry
        // seven series.
        let visible = series.map { entry in
            Dictionary(
                entry.points
                    .filter { $0.timestamp >= start && $0.timestamp <= end }
                    .map { ($0.timestamp, $0.value) },
                uniquingKeysWith: { _, latest in latest }
            )
        }

        var stamps = Set<TimeInterval>()
        for column in visible { stamps.formUnion(column.keys) }

        var rows = [header(for: series)]
        for timestamp in stamps.sorted() {
            let fields = visible.map { column in
                column[timestamp].map { number($0) } ?? ""
            }
            rows.append(row([time(timestamp, in: timeZone)] + fields))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func header(
        for series: [(descriptor: MetricDescriptor, points: [Sample])]
    ) -> String {
        row(["Time"] + series.map { column($0.descriptor) })
    }

    /// "Disk Read (B/s)". The group is dropped when it only repeats the name,
    /// which is the same rule the gauge captions use — "Fans Fans" reads as a
    /// mistake.
    static func column(_ descriptor: MetricDescriptor) -> String {
        let name = descriptor.group == descriptor.name
            ? descriptor.name
            : "\(descriptor.group) \(descriptor.name)"
        return "\(name) (\(Format.baseUnit(descriptor.unit)))"
    }

    /// Fixed decimals rather than Swift's shortest round-trip, which writes
    /// small numbers in exponent form. `1e-05` is a valid double and a value
    /// some spreadsheets read as text.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.4f", value)
    }

    static func time(_ timestamp: TimeInterval, in timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func row(_ fields: [String]) -> String {
        fields.map(escaped).joined(separator: ",")
    }

    /// RFC 4180: a field holding a comma, a quote or a newline is wrapped in
    /// quotes, and its own quotes are doubled.
    static func escaped(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
