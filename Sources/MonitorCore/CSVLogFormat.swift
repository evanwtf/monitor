import Foundation

/// Turns a batch of samples into a wide CSV row for the rotating log.
///
/// Wide rather than long: one row per timestamp, one column per metric, so a
/// human can scan across a row and a tool can load it into a table. The header
/// is written once per file, from the descriptors, so a fanless Mac simply has
/// no fan column.
///
/// A temperature is written twice — in °C and in °F — because a log read by a
/// human or a tool on either side of the Atlantic should not make the reader
/// convert. Two time columns — ISO8601 in UTC and epoch millis — because a human
/// reads the first and a tool reads the second. A metric that produced no
/// sample this tick leaves an empty field, never a zero, so a gap does not read
/// as a cold die.
public enum CSVLogFormat {
    /// One output column: a name and how to format a value for it.
    struct Column {
        let name: String
        let format: (Double) -> String
    }

    public static func header(hostname _: String, descriptors: [MetricDescriptor]) -> String {
        let names = descriptors.flatMap { columns(for: $0) }.map(\.name)
        return CSVExport.row(["hostname", "time_iso8601", "time_epoch_ms"] + names)
    }

    public static func row(
        hostname: String,
        timestamp: TimeInterval,
        values: [MetricID: Double],
        descriptors: [MetricDescriptor]
    ) -> String {
        let iso = iso8601(timestamp)
        let epochMs = Int64((timestamp * 1000).rounded())
        let fields = descriptors.flatMap { descriptor in
            columns(for: descriptor).map { column in
                values[descriptor.id].map(column.format) ?? ""
            }
        }
        return CSVExport.row([hostname, iso, String(epochMs)] + fields)
    }

    /// A temperature becomes two columns, °C and °F; anything else is one.
    static func columns(for descriptor: MetricDescriptor) -> [Column] {
        if descriptor.unit == .celsius {
            return [
                Column(name: "\(descriptor.id.rawValue) (°C)") { number($0, decimals: 2) },
                Column(name: "\(descriptor.id.rawValue) (°F)") { number(
                    $0 * 9 / 5 + 32,
                    decimals: 2
                ) },
            ]
        }
        return [
            Column(name: "\(descriptor.id.rawValue) (\(Format.baseUnit(descriptor.unit)))") {
                number($0, unit: descriptor.unit)
            },
        ]
    }

    /// Two decimals for anything fractional; whole numbers for the units that
    /// are counts. A log is read for trends, not for the fourth decimal.
    static func number(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .rpm, .bytes, .count, .hertz: number(value, decimals: 0)
        default: number(value, decimals: 2)
        }
    }

    static func number(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    static func iso8601(_ timestamp: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
