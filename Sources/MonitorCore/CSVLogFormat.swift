import Foundation

/// Turns a batch of samples into a wide CSV row for the rotating log.
///
/// Wide rather than long: one row per timestamp, one column per metric, so a
/// human can scan across a row and a tool can load it into a table. The header
/// is written once per file, from the descriptors, so a fanless Mac simply has
/// no fan column.
///
/// Two time columns — ISO8601 in UTC and epoch millis — because a human reads
/// the first and a tool reads the second, and neither should have to parse the
/// other. A metric that produced no sample this tick leaves an empty field,
/// never a zero, so a gap does not read as a cold die.
public enum CSVLogFormat {
    public static func header(hostname _: String, descriptors: [MetricDescriptor]) -> String {
        CSVExport.row(["hostname", "time_iso8601", "time_epoch_ms"] + descriptors.map(column))
    }

    public static func row(
        hostname: String,
        timestamp: TimeInterval,
        values: [MetricID: Double],
        descriptors: [MetricDescriptor]
    ) -> String {
        let iso = iso8601(timestamp)
        let epochMs = Int64((timestamp * 1000).rounded())
        let fields = descriptors.map { values[$0.id].map(CSVExport.number) ?? "" }
        return CSVExport.row([hostname, iso, String(epochMs)] + fields)
    }

    /// "sensor.temperature.cpu (°C)". The metric id is the stable key; the unit
    /// rides along so a consumer does not have to know it from elsewhere.
    static func column(_ descriptor: MetricDescriptor) -> String {
        "\(descriptor.id.rawValue) (\(Format.baseUnit(descriptor.unit)))"
    }

    static func iso8601(_ timestamp: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
