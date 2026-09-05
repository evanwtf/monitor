import Foundation
@testable import MonitorCore
import Testing

struct LogRetentionTests {
    @Test func seconds() {
        #expect(LogRetention.oneHour.seconds == 3600)
        #expect(LogRetention.sixHours.seconds == 6 * 3600.0)
        #expect(LogRetention.sevenDays.seconds == 7 * 86400.0)
        #expect(LogRetention.forever.seconds == nil)
    }

    @Test func periodIsMidnightLocal() throws {
        let calendar = Calendar.current
        let noon = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 10
        )))
        let midnight = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4
        )))
        let period = LogRetention.period(for: noon.timeIntervalSince1970)
        #expect(period == midnight.timeIntervalSince1970)
    }

    @Test func periodReadsBackFromFilename() throws {
        let calendar = Calendar.current
        let day = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4
        )))
        let parsed = LogRetention.period(from: "sensors.my-host.2026_09_04.log")
        #expect(parsed == day.timeIntervalSince1970)
    }
}
