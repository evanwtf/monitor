import Foundation

/// How long a CSV log is kept, and how often the file rolls.
///
/// The cadence follows the window so a sub-day window can actually be honored:
/// a daily file cannot hold a one-hour window — a "1h" retention would keep up
/// to 24h of data — so sub-day windows roll hourly and day-and-up windows roll
/// daily. The boundary is local time, 00:00:00 for daily and the top of the
/// hour for hourly, so a file's name reads as the day or hour it covers.
public enum LogRetention: String, CaseIterable, Sendable {
    case oneHour = "1h"
    case sixHours = "6h"
    case oneDay = "24h"
    case twoDays = "48h"
    case threeDays = "3d"
    case fiveDays = "5d"
    case sevenDays = "7d"
    case fourteenDays = "14d"
    case thirtyDays = "30d"
    case forever

    /// How long data is kept. Nil means "forever" — you own the disk.
    public var seconds: TimeInterval? {
        switch self {
        case .oneHour: 3600
        case .sixHours: 6 * 3600
        case .oneDay: 24 * 3600
        case .twoDays: 2 * 86400
        case .threeDays: 3 * 86400
        case .fiveDays: 5 * 86400
        case .sevenDays: 7 * 86400
        case .fourteenDays: 14 * 86400
        case .thirtyDays: 30 * 86400
        case .forever: nil
        }
    }

    /// How often the log file rolls over. Sub-day windows roll hourly, because
    /// a daily file cannot honor a sub-day window; everything else rolls daily.
    public var cadence: TimeInterval {
        guard let seconds else { return 86400 }
        return seconds < 86400 ? 3600 : 86400
    }

    /// The date part of a file name, which is also how a file's period is read
    /// back for retention. Daily files carry a date, hourly files a date and
    /// hour.
    public var dateFormat: String { Self.dateFormat(for: cadence) }

    static func dateFormat(for cadence: TimeInterval) -> String {
        cadence >= 86400 ? "yyyy-MM-dd" : "yyyy-MM-dd-HH"
    }

    /// The start of the cadence period a timestamp falls in, in local time.
    public static func period(for timestamp: TimeInterval,
                              cadence: TimeInterval) -> TimeInterval
    {
        let date = Date(timeIntervalSince1970: timestamp)
        let calendar = Calendar.current
        let components = cadence >= 86400
            ? calendar.dateComponents([.year, .month, .day], from: date)
            : calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: components)?.timeIntervalSince1970 ?? timestamp
    }

    /// The period a file covers, read back from its name. The date is the last
    /// component of the name, so a hostname that itself contains dashes cannot
    /// confuse the parse.
    public static func period(from filename: String, cadence: TimeInterval) -> TimeInterval? {
        let base = filename.hasSuffix(".csv") ? String(filename.dropLast(4)) : filename
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.dateFormat = dateFormat(for: cadence)
        let dateLength = cadence >= 86400 ? 10 : 13
        guard base.count >= dateLength else { return nil }
        guard let date = formatter.date(from: String(base.suffix(dateLength)))
        else { return nil }
        return date.timeIntervalSince1970
    }
}
