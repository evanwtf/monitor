import Foundation

/// How long a CSV log is kept.
///
/// The log rolls once a day, at 00:00:00 local time, so a file's name reads as
/// the day it covers. Retention deletes whole files older than the window; a
/// sub-day window therefore keeps today's file, which can hold up to a day of
/// data — the window is a floor, not a promise at sub-day granularity.
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

    /// The start of the day a timestamp falls in, in local time.
    public static func period(for timestamp: TimeInterval) -> TimeInterval {
        let date = Date(timeIntervalSince1970: timestamp)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: components)?.timeIntervalSince1970 ?? timestamp
    }

    /// The day a file covers, read back from its name. The date and time are
    /// the last components of the name, so a hostname that itself contains
    /// dashes or dots cannot confuse the parse. The time is ignored: the period
    /// is the start of the day, so retention still deletes whole days.
    public static func period(from filename: String) -> TimeInterval? {
        let base = filename.hasSuffix(".csv") ? String(filename.dropLast(4)) : filename
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy_MM_dd_HH_mm_ss"
        guard base.count >= 19 else { return nil }
        guard let date = formatter.date(from: String(base.suffix(19))) else { return nil }
        return period(for: date.timeIntervalSince1970)
    }
}
